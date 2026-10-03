#!/usr/bin/env python3
"""Record a MacLinuxGPU observer fixture for StudioTelemetry.

Reads the amdgpu device's telemetry through the dext's read-only observer
user client (type 1), the same way amdgpu_mtopg does, and writes a JSON
fixture that FixtureObserverConnection replays on the iPad simulator.

  capture_fixture.py --name r9700-idle --duration 60 -o r9700-idle.json
  capture_fixture.py --name r9700-load --wait-for-load 3600 --duration 60 -o r9700-load.json

Only an observer is opened: it never claims PCI, joins or opens a session,
or touches queues, and it sends no work to the GPU. Files are read from a
fixed allowlist (a few device attributes, such as psp_vbflash, act on read
and are never touched). The protocol helpers come from mac_linuxgpu's
scripts/read-sysfs.py.

Timing follows amdgpu_mtopg's sampler: every 100 ms five GRBM_STATUS reads
8 ms apart (AMDGPU_INFO_READ_MMR_REG), and the slow attributes once a second.
"""
import argparse
import ctypes as c
import datetime
import importlib.util
import json
import os
import platform
import struct
import sys
import time

DEFAULT_READ_SYSFS = os.path.expanduser(
    "~/Documents/Development/mac_linuxgpu/scripts/read-sysfs.py")

# amdgpu_mtopg LinuxPaths.device, plus gpu_metrics and a few identity files
# that are plain show() reads.
DEVICE_FILES = [
    "gpu_busy_percent", "mem_busy_percent",
    "mem_info_vram_used", "mem_info_vram_total",
    "mem_info_vis_vram_used", "mem_info_vis_vram_total",
    "mem_info_gtt_used", "mem_info_gtt_total",
    "pp_dpm_sclk", "pp_dpm_mclk", "pp_dpm_fclk", "pp_dpm_socclk", "pp_dpm_pcie",
    "power_dpm_force_performance_level",
    "current_link_speed", "current_link_width", "max_link_speed", "max_link_width",
    "vendor", "device", "revision",
    "gpu_metrics",
]
STATIC_FILES = [
    "ip_discovery/die/0/GC/0/base_addr",
    "subsystem_vendor", "subsystem_device", "vbios_version", "mem_info_vram_vendor",
]
# Every hwmon attribute is a sensor show(); the listing decides which exist.
HWMON_SUFFIXES = ("_input", "_label", "_average", "_cap", "_cap_max", "_cap_min",
                  "_cap_default", "_max", "_min", "_crit", "_crit_hyst", "_emergency",
                  "_enable", "_target")
HWMON_EXACT = ("name", "pwm1", "pwm1_max", "pwm1_min")

RUNTIME_BUILD = 43
QUERY_INFO = 21
TAG_PROBE_STATUS = 0x4c50524f   # "LPRO"


def load_read_sysfs(path):
    spec = importlib.util.spec_from_file_location("read_sysfs", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def connect(rs):
    """An observer connection whose call() also returns the IOReturn and any
    number of output words (read-sysfs.py's connect() assumes three)."""
    io = c.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
    system = c.CDLL("/usr/lib/libSystem.B.dylib")
    io.IOServiceNameMatching.argtypes = [c.c_char_p]
    io.IOServiceNameMatching.restype = c.c_void_p
    io.IOServiceGetMatchingService.argtypes = [c.c_uint, c.c_void_p]
    io.IOServiceGetMatchingService.restype = c.c_uint
    io.IORegistryEntryGetRegistryEntryID.argtypes = [c.c_uint, c.POINTER(c.c_uint64)]
    io.IOServiceOpen.argtypes = [c.c_uint, c.c_uint, c.c_uint, c.POINTER(c.c_uint)]
    io.IOServiceOpen.restype = c.c_int
    io.IOObjectRelease.argtypes = [c.c_uint]
    io.IOServiceClose.argtypes = [c.c_uint]
    io.IOServiceClose.restype = c.c_int
    io.IOConnectCallMethod.argtypes = [c.c_uint, c.c_uint, c.POINTER(c.c_uint64), c.c_uint,
                                       c.c_void_p, c.c_size_t, c.POINTER(c.c_uint64),
                                       c.POINTER(c.c_uint), c.c_void_p, c.POINTER(c.c_size_t)]
    io.IOConnectCallMethod.restype = c.c_int
    service = io.IOServiceGetMatchingService(0, io.IOServiceNameMatching(b"MacLinuxGPU"))
    if not service:
        raise rs.DriverError("MacLinuxGPU registry service was not found")
    registry = c.c_uint64()
    io.IORegistryEntryGetRegistryEntryID(service, c.byref(registry))
    port = c.c_uint()
    try:
        task = c.c_uint.in_dll(system, "mach_task_self_").value
        result = io.IOServiceOpen(service, task, rs.OBSERVER_CLIENT, c.byref(port))
    finally:
        io.IOObjectRelease(service)
    if result:
        raise rs.DriverError(f"observer open failed: {result & 0xffffffff:#x}")

    def raw(selector, scalars, data, capacity, words):
        inputs = (c.c_uint64 * max(len(scalars), 1))(*scalars)
        outputs = (c.c_uint64 * max(words, 1))()
        count = c.c_uint(words)
        out = c.create_string_buffer(max(capacity, 1))
        size = c.c_size_t(capacity)
        source = c.create_string_buffer(data, len(data)) if data else None
        result = io.IOConnectCallMethod(port, selector, inputs, len(scalars),
                                        source, len(data) if data else 0,
                                        outputs, c.byref(count),
                                        out if capacity else None, c.byref(size))
        return result & 0xffffffff, list(outputs[:count.value]), out.raw[:size.value]

    def call(selector, scalars, data, capacity):
        code, words, payload = raw(selector, scalars, data, capacity, 3)
        if code == rs.NOT_READY:
            raise rs.DriverError("not ready: the upstream driver is not running in an open session")
        if code == rs.NOT_PERMITTED:
            raise rs.DriverError("selector not permitted for observers")
        if code:
            raise rs.DriverError(f"call {selector} failed: {code:#x}")
        return words, payload

    def close():
        io.IOServiceClose(port)

    return registry.value, raw, call, close


def file_entry(rs, call, path):
    """{"text": ...} for UTF-8 payloads, {"hex": ...} for binary, {"errno": N}."""
    try:
        data = rs.read_file(call, path)
    except OSError as error:
        return {"errno": error.errno or 5}
    if path.endswith("gpu_metrics"):
        return {"hex": data.hex()}
    try:
        return {"text": data.decode("utf-8")}
    except UnicodeDecodeError:
        return {"hex": data.hex()}


def connect_when_ready(rs, timeout, period=5):
    """An observer connection once the upstream driver runs in a session.
    Each attempt opens a fresh observer and closes it again unless the
    driver answers, so a GPU that is unplugged and reattached (a new
    MacLinuxGPU service) is picked up. The observer never opens a session."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            connection = connect(rs)
            try:
                rs.read_file(connection[2], "gpu_busy_percent")
                return connection
            except (OSError, rs.DriverError):
                connection[3]()
        except rs.DriverError:
            pass
        if time.monotonic() >= deadline:
            return None
        time.sleep(period)


def wait_for_load(rs, call, timeout, threshold):
    """Poll gpu_busy_percent once a second (no GRBM) until it reaches the
    threshold. Returns True on load, False on timeout."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            busy = int(rs.read_file(call, "gpu_busy_percent").decode().strip())
            if busy >= threshold:
                return True
        except (OSError, ValueError, rs.DriverError):
            pass
        time.sleep(1)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", required=True)
    parser.add_argument("--description", default="")
    parser.add_argument("--duration", type=float, default=60)
    parser.add_argument("--wait-for-load", type=float, metavar="SECONDS", default=0,
                        help="first wait up to SECONDS for gpu_busy_percent >= --threshold")
    parser.add_argument("--threshold", type=int, default=20)
    parser.add_argument("--wait-for-ready", type=float, metavar="SECONDS", default=0,
                        help="first wait up to SECONDS for the upstream driver to run in a session")
    parser.add_argument("--read-sysfs", default=DEFAULT_READ_SYSFS)
    parser.add_argument("-o", "--output", required=True)
    args = parser.parse_args()

    rs = load_read_sysfs(args.read_sysfs)
    if args.wait_for_ready:
        print(f"waiting up to {args.wait_for_ready:.0f} s for the upstream driver", file=sys.stderr)
        connection = connect_when_ready(rs, args.wait_for_ready)
        if connection is None:
            print("driver never became ready; nothing recorded", file=sys.stderr)
            return 3
    else:
        connection = connect(rs)
    registry, raw, call, close = connection
    try:
        if args.wait_for_load:
            print(f"waiting up to {args.wait_for_load:.0f} s for gpu_busy_percent >= {args.threshold}",
                  file=sys.stderr)
            if not wait_for_load(rs, call, args.wait_for_load, args.threshold):
                print("no load observed; nothing recorded", file=sys.stderr)
                return 2

        kr, build_words, _ = raw(RUNTIME_BUILD, [], None, 0, 4)
        selectors = {"runtimeBuild": {"kr": kr, "words": build_words}}
        kr, probe_words, _ = raw(QUERY_INFO, [TAG_PROBE_STATUS], None, 0, 5)
        selectors["probeStatus"] = {"kr": kr, "words": probe_words}

        listings = {"hwmon": rs.read_file(call, "hwmon", rs.OP_LIST).decode()}
        hwmon_dir = next((name for kind, name in rs.list_dir(call, "hwmon")
                          if kind == "d" and name.startswith("hwmon")), None)
        hwmon_files = []
        if hwmon_dir:
            listings[f"hwmon/{hwmon_dir}"] = rs.read_file(call, f"hwmon/{hwmon_dir}", rs.OP_LIST).decode()
            hwmon_files = [f"hwmon/{hwmon_dir}/{name}" for kind, name in rs.list_dir(call, f"hwmon/{hwmon_dir}")
                           if kind == "f" and (name in HWMON_EXACT or name.endswith(HWMON_SUFFIXES))]
        static = {path: file_entry(rs, call, path) for path in STATIC_FILES}

        base_text = static["ip_discovery/die/0/GC/0/base_addr"].get("text", "")
        grbm_offset = int(base_text.split()[0], 16) + rs.GRBM_STATUS if base_text else None
        grbm_args = struct.pack("<IIII", grbm_offset, 1, 0xffffffff, 0) if grbm_offset else None

        frames, grbm = [], []
        stopped_early = None
        start = time.monotonic()
        next_slow = start
        tick = start
        print(f"recording {args.duration:.0f} s", file=sys.stderr)
        while True:
            now = time.monotonic()
            if now - start >= args.duration:
                break
            if now >= next_slow:
                t = now - start
                try:
                    files = {path: file_entry(rs, call, path) for path in DEVICE_FILES + hwmon_files}
                except rs.DriverError as error:
                    # The session closed mid-capture: keep what was recorded.
                    print(f"stopping early: {error}", file=sys.stderr)
                    stopped_early = str(error)
                    break
                frames.append({"t": round(t, 3), "files": files})
                next_slow += 1.0
            if grbm_args:
                for i in range(5):
                    if i:
                        time.sleep(0.008)
                    try:
                        value, = struct.unpack("<I", rs.drm_info(call, rs.INFO_READ_MMR_REG, grbm_args, 4))
                        grbm.append([round((time.monotonic() - start) * 1000, 1), value])
                    except (OSError, rs.DriverError) as error:
                        print(f"GRBM_STATUS: {error}", file=sys.stderr)
                        grbm_args = None
                        break
            tick += 0.1
            delay = tick - time.monotonic()
            if delay > 0:
                time.sleep(delay)
    finally:
        close()

    busy = [int(f["files"]["gpu_busy_percent"]["text"]) for f in frames
            if "text" in f["files"].get("gpu_busy_percent", {})]
    active = sum(1 for _, v in grbm if v & rs.GUI_ACTIVE)
    fixture = {
        "schema": "lemonseed.observer-fixture",
        "version": 1,
        "name": args.name,
        "description": args.description,
        "capture": {
            "date": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "host": f"macOS {platform.mac_ver()[0]} ({platform.machine()})",
            "driver": "mac_linuxgpu",
            "runtimeBuild": build_words[3] if len(build_words) == 4 else None,
            "tool": "Packages/StudioTelemetry/Tools/capture_fixture.py",
            "durationSeconds": round(time.monotonic() - start, 3),
            "stoppedEarly": stopped_early,
            "slowPeriodMs": 1000,
            "grbmTickMs": 100,
            "grbmSamplesPerTick": 5,
            "summary": {
                "gpuBusyPercentMin": min(busy) if busy else None,
                "gpuBusyPercentMax": max(busy) if busy else None,
                "grbmActiveFraction": round(active / len(grbm), 4) if grbm else None,
            },
        },
        "device": {"service": "MacLinuxGPU", "registryID": registry},
        "selectors": selectors,
        "listings": listings,
        "static": static,
        "frames": frames,
        "grbm": {"offset": grbm_offset, "samples": grbm},
    }
    with open(args.output, "w") as out:
        json.dump(fixture, out, indent=1, sort_keys=False)
        out.write("\n")
    print(f"wrote {args.output}: {len(frames)} frames, {len(grbm)} GRBM samples, "
          f"gpu_busy {fixture['capture']['summary']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
