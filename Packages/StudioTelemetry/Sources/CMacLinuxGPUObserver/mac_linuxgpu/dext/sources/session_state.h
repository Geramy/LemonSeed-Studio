/* Cached session state shared by the user client, the host app and the
 * offline readers (scripts/read-driver-log.py keeps the same numbers).
 *
 * The session-state snapshot (QueryInfo tag DEXT_COMPUTE_QUERY_SESSION_STATE)
 * is built from lifecycle variables only: it never claims PCI, touches MMIO
 * or configuration space, or dereferences upstream device state.
 *
 *   out[0] layout version (MLG_SESSION_STATE_VERSION)
 *   out[1] MLG_SESSION_FLAG_* bits
 *   out[2] quarantine cause (MLG_QUARANTINE_*), first trigger wins
 *   out[3] cause code, sign-extended (the failing step's return value)
 *   out[4] step that observed a definite PCI fault (cause MLG_QUARANTINE_PCI_FAULT)
 *   out[5] last bus-master isolation result, sign-extended (flag ISOLATION_ATTEMPTED)
 *   out[6] release blocker (MLG_RELEASE_*); MLG_RELEASE_READY when releasable
 *   out[7] session generation
 *   out[8] session participants
 */
#ifndef MACLINUXGPU_SESSION_STATE_H
#define MACLINUXGPU_SESSION_STATE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "power_state.h"

#define MLG_SESSION_STATE_VERSION 1u
#define MLG_SESSION_STATE_WORDS   9u

enum mlg_session_flag {
	MLG_SESSION_FLAG_CLOSING             = 1u << 0,
	MLG_SESSION_FLAG_QUARANTINED         = 1u << 1,
	MLG_SESSION_FLAG_STOPPING            = 1u << 2,
	MLG_SESSION_FLAG_PCI_OPEN            = 1u << 3,
	MLG_SESSION_FLAG_MODULES_RUNNING     = 1u << 4,
	MLG_SESSION_FLAG_FINAL_CLEANUP       = 1u << 5, /* interrupt drain completed */
	MLG_SESSION_FLAG_RELEASABLE          = 1u << 6,
	MLG_SESSION_FLAG_RESTART_REQUIRED    = 1u << 7,
	MLG_SESSION_FLAG_RAW_BAR_MAPPED      = 1u << 8,
	MLG_SESSION_FLAG_RUNTIME_DEVICE      = 1u << 9,
	MLG_SESSION_FLAG_ISOLATION_ATTEMPTED = 1u << 10,
	MLG_SESSION_FLAG_DEVICE_REMOVED      = 1u << 11, /* surprise removal: the GPU left the bus */
	MLG_SESSION_FLAG_RETIRING            = 1u << 12, /* Retire: no new session (an upgrade) */
	MLG_SESSION_FLAG_GPU_WEDGED          = 1u << 13, /* recovery failed: power-cycle the GPU */
};

/* Which close/probe step quarantined the session. */
enum mlg_quarantine_cause {
	MLG_QUARANTINE_NONE               = 0,
	MLG_QUARANTINE_RAW_BAR_MAPPING    = 1,  /* raw BAR mapping lifetime uncertain */
	MLG_QUARANTINE_SHUTDOWN_HOLD      = 2,  /* DMA shutdown reservation failed */
	MLG_QUARANTINE_COMPUTE_UNCERTAIN  = 3,  /* dext_compute_stop: GPU completion uncertain */
	MLG_QUARANTINE_IRQ_CANCEL         = 4,  /* interrupt cancellation failed */
	MLG_QUARANTINE_ENDPOINT_ISOLATION = 5,  /* shutdown function reset failed or was refused */
	MLG_QUARANTINE_DMA_RETAINED       = 6,  /* dext_dma_fini found retained backing */
	MLG_QUARANTINE_PCI_FAULT          = 7,  /* definite PCI transport fault; code = fault kind */
	MLG_QUARANTINE_PROBE_HOLD         = 8,  /* probe DMA reservation failed */
	MLG_QUARANTINE_PROBE_RETAINED     = 9,  /* failed-probe ownership retained */
	MLG_QUARANTINE_PROBE_COMMIT       = 10, /* probe DMA commit failed */
	MLG_QUARANTINE_CLIENT_RELEASE     = 11, /* shared-session client cleanup failed */
	MLG_QUARANTINE_RELEASE_FAILED     = 12, /* explicit release attempt failed */
};

/* Why a quarantined session cannot be released now. */
enum mlg_release_blocker {
	MLG_RELEASE_READY             = 0,
	MLG_RELEASE_NOT_QUARANTINED   = 1,
	MLG_RELEASE_IRQ_PENDING       = 2,  /* drain requested, completion not yet run */
	MLG_RELEASE_IRQ_FAILED        = 3,  /* a source still owns live callbacks */
	MLG_RELEASE_UPSTREAM_RETAINED = 4,  /* upstream driver or runtime device not removed */
	MLG_RELEASE_COMPUTE_RETAINED  = 5,  /* compute context or uncertain GPU work retained */
	MLG_RELEASE_RAW_BAR_MAPPED    = 6,  /* a client still holds a raw BAR mapping */
	MLG_RELEASE_PARTICIPANTS      = 7,  /* session clients have not all exited */
	MLG_RELEASE_DMA_OWNED         = 8,  /* live DMA owner, alias, operation or failed completion */
	MLG_RELEASE_PCI_FAULT         = 9,  /* definite PCI transport fault */
	MLG_RELEASE_PCI_BUSY          = 10, /* PCI admission has not drained */
	MLG_RELEASE_RESET_FAILED      = 11, /* a release attempt could not reset the endpoint */
};

/* Blockers that no later event in this process can clear. Only these make a
 * restart necessary; the others clear once a client exits or a drain ends. */
static inline bool mlg_release_blocker_permanent(uint32_t blocker)
{
	switch (blocker) {
	case MLG_RELEASE_IRQ_FAILED:
	case MLG_RELEASE_UPSTREAM_RETAINED:
	case MLG_RELEASE_COMPUTE_RETAINED:
	case MLG_RELEASE_DMA_OWNED:
	case MLG_RELEASE_PCI_FAULT:
	case MLG_RELEASE_RESET_FAILED:
		return true;
	default:
		return false;
	}
}

/* Observer user clients (type MLG_USER_CLIENT_OBSERVER) never join or close
 * a session. They may call selectors that read cached state (the power
 * state among them, power_state.h), the entitlement-checked release and
 * power-request selectors, the two Linux read paths below,
 * which run upstream callbacks while the driver runs and never claim PCI,
 * join the session or touch queues, the self-contained submission
 * self-test (DrmSelfTest), the display test (Display) and the entitlement-checked
 * Retire an installer sends before a driver upgrade. Linux-file clients are type 2
 * (MLG_USER_CLIENT_LINUX_FILE, linuxu/headers/rt/lx_abi.h). */
#define MLG_USER_CLIENT_SESSION  0u
#define MLG_USER_CLIENT_OBSERVER 1u

#define MLG_SELECTOR_PING                0u
#define MLG_SELECTOR_QUERY_INFO          21u
#define MLG_SELECTOR_RUNTIME_BUILD       43u
#define MLG_SELECTOR_RELEASE_QUARANTINE  61u
/* Outside the MacAMDGPU selector range (0-73): MacLinuxGPU's Linux paths. */
#define MLG_SELECTOR_SYSFS_READ          80u
#define MLG_SELECTOR_DRM_INFO            81u
#define MLG_SELECTOR_DRM_SELFTEST        82u
/* 83 is MLG_SELECTOR_POWER (power_state.h). 96-103 are the Linux-file selectors
 * (linuxu/headers/rt/lx_abi.h). */
#define MLG_SELECTOR_DISPLAY             84u
#define MLG_SELECTOR_RETIRE              85u
#define MLG_SELECTOR_EVENT               86u
#define MLG_SELECTOR_EVENT_WAIT          87u
#define MLG_SELECTOR_OWNER_RESULT        88u

/* Calls that never sleep, and every other call.
 *
 * DriverKit delivers every client's calls, and the driver's own Stop, on
 * one thread. A call that sleeps there (an upstream lock, an allocation
 * that evicts, a fence, a probe) holds them all; on a GPU that stopped it
 * holds them forever (build 241). So only the calls
 * mlg_call_runs_on_delivery() names (cached state, the power wait's
 * registration) run on that thread, synchronously as always. Every other
 * selector (the session client's whole MacAMDGPU set, InitDevice and
 * HostWindow from any client, the observer's self-test, Retire and
 * ReleaseQuarantine, EVENT) must be called with IOConnectCallAsync*: the
 * call returns at once (out[0] = its token when the caller asked for any
 * scalar output), the selector runs on the driver's session queue, in the
 * order the calls arrived, with the same arguments, and the call completes
 * with async data
 *   [0] token, [1] the selector's IOReturn, [2] n, its scalar output count
 *   (at most MLG_OWNER_ASYNC_MAX_SCALARS, as many as the caller asked
 *   for), [3] bytes of its structure output, [4 .. 4+n) its scalar outputs
 *   when n is at most MLG_OWNER_ASYNC_SCALARS (what the completion holds).
 * OWNER_RESULT, in [0] = token, returns the rest once (struct out, sized by
 * the caller), or kIOReturnNotFound: the n scalars first when there are more
 * than the completion holds (n * 8 bytes), then the structure output. A synchronous call of
 * such a selector is refused with kIOReturnNotPermitted (and logged).
 * EVENT_WAIT keeps its own completion (above): its registration runs on
 * the session queue, then the wait on a driver thread; a wait that does
 * not start completes at once with [1] = -errno. SysfsRead and DrmInfo
 * stay synchronous, bounded: the read runs on a driver thread, and the
 * call waits at most MLG_BOUNDED_READ_MS for it (kIOReturnTimeout; while
 * it is still running another is kIOReturnBusy). */
/* The first runtime build (RuntimeBuild's out[3], the compiled build) that
 * serves session calls this way: a client checks it before an async call,
 * since an older driver answers such a call synchronously and never
 * completes it. */
#define MLG_SESSION_CALLS_ASYNC_BUILD 243u
#define MLG_OWNER_ASYNC_HEADER   4u
#define MLG_OWNER_ASYNC_SCALARS  12u
#define MLG_OWNER_ASYNC_WORDS    (MLG_OWNER_ASYNC_HEADER + MLG_OWNER_ASYNC_SCALARS)
/* IOKit's limit on a call's scalar outputs (QueryInfo's topology is 16). */
#define MLG_OWNER_ASYNC_MAX_SCALARS 16u
#define MLG_BOUNDED_READ_MS      250u

/* Interrupt-driven waits on KFD signal events (a session client on the KFD
 * path; rt/kfd_session.h has the semantics).
 *
 * EVENT       in:  [0] op, [1] event id (DESTROY, SET)
 *             out: [0] 0 or -errno (Linux values), and for CREATE
 *                  [1] event id, [2] trigger (amd_signal_t.event_id),
 *                  [3] mailbox VA (amd_signal_t.event_mailbox_ptr)
 *             -ENODEV: no KFD process backs this client (legacy path).
 * EVENT_WAIT  called with IOConnectCallAsync*. in: [0] token (echoed),
 *             [1] event count, [2] 1 = all of them, [3] timeout in ms
 *             (at most MLG_EVENT_WAIT_MAX_MS); struct in: the event ids
 *             (uint32_t each, at most MLG_EVENT_WAIT_IDS)
 *             out: [0] 0, or -errno when the wait did not start (then
 *             nothing completes; -EAGAIN: every waiting thread is busy)
 *             completion: async data [0] token, [1] 0 or -errno, [2] the
 *             KFD wait result (0 complete, 1 timeout, 2 failed).
 * The wait sleeps on a driver thread until KFD's interrupt handler signals
 * an event it names, or the timeout: the client's thread sleeps in its
 * own receive until the completion arrives. Nothing polls. */
#define MLG_EVENT_OP_CREATE     0u
#define MLG_EVENT_OP_DESTROY    1u
#define MLG_EVENT_OP_SET        2u
#define MLG_EVENT_WORDS         4u
#define MLG_EVENT_WAIT_IDS      64u
#define MLG_EVENT_WAIT_MAX_MS   1000u
#define MLG_EVENT_WAIT_WORDS    3u

/* Retire: hand the GPU to a replacement driver (a system extension upgrade).
 *
 * macOS does not stop a running driver extension when an activation request
 * replaces it: the old version stays "terminating for upgrade via delegate"
 * and the new one attaches only after every instance of the old one is gone.
 * Retire is how the installer makes an instance go, without killing it:
 *
 *   QUIESCE    admit no new session, close an open one through the normal
 *              close (upstream removal, interrupt drain, endpoint reset,
 *              provider close). The instance stays attached and idle.
 *   TERMINATE  QUIESCE, then ask IOKit to terminate this driver instance
 *              (IOService::Terminate) once nothing of the session is left:
 *              its clients and the driver are stopped and the process exits.
 *              Send it only once macOS accepted the replacement; otherwise
 *              the GPU stays without a driver until it is attached again.
 *   RESUME     undo QUIESCE (a replacement that failed or was deferred).
 *   DISCONNECT "Disconnect GPU": close the session now, as QUIESCE with
 *              MLG_RETIRE_FORCE, so the GPU is safe to unplug, whatever
 *              clients it has; then admit sessions again, so the next
 *              program brings the GPU up. The clients of the closed session
 *              get kIOReturnNoDevice ("the GPU was disconnected") on every
 *              further call; out[2] counts them. IDLE once closed.
 *
 * Nothing is forced into quarantine: a client holding a raw BAR mapping
 * refuses the close (RAW_BAR), and so do other session clients unless
 * MLG_RETIRE_FORCE is given (their next call fails NotAttached or NotOpen,
 * as after any close). A quarantined session is released when it is
 * provably quiescent; otherwise it stays (QUARANTINED, out[2] the blocker):
 * restart the Mac, never kill the driver. Requires the session-release
 * entitlement; observers may call it.
 *   scalar in:  [0] MLG_RETIRE_OP_*, [1] MLG_RETIRE_FORCE or 0,
 *               [2] MLG_RETIRE_CONFIRM
 *   scalar out: [0] IOReturn: Success (IDLE, TERMINATING, STOPPING,
 *               RESUMED), NotReady (CLOSING; QUARANTINED with a blocker that
 *               can clear), Busy (CLIENTS, RAW_BAR), Error (QUARANTINED for
 *               good, or Terminate failed)
 *               [1] MLG_RETIRE_*
 *               [2] CLIENTS: the other session clients; QUARANTINED: the
 *               MLG_RELEASE_* blocker; else 0
 * Repeat the call to follow a close; session state flag RETIRING shows it. */
#define MLG_RETIRE_OP_QUIESCE   0u
#define MLG_RETIRE_OP_TERMINATE 1u
#define MLG_RETIRE_OP_RESUME    2u
#define MLG_RETIRE_OP_DISCONNECT 3u
#define MLG_RETIRE_FORCE        1u
#define MLG_RETIRE_CONFIRM      0x52455452ULL /* "RETR" */
#define MLG_RETIRE_WORDS        3u

/* How long a session call may hold the session queue while the driver's
 * Stop or a Retire waits behind it before the driver makes GPU work
 * complete at once (MacLinuxGPUXcode.mm's session_watchdog_step), and how
 * long one watch lasts. */
#define MLG_SESSION_BLOCK_BOUND_MS 30000u
#define MLG_SESSION_WATCH_MAX_S    600u
static inline bool mlg_session_blocked(uint64_t job_since_ns, uint64_t now_ns, uint64_t bound_ns)
{
	return job_since_ns && now_ns > job_since_ns && now_ns - job_since_ns >= bound_ns;
}

enum mlg_retire_state {
	MLG_RETIRE_IDLE        = 0, /* no session; new sessions refused */
	MLG_RETIRE_TERMINATING = 1, /* termination requested: stops, then the process exits */
	MLG_RETIRE_CLOSING     = 2, /* the session is closing; what was asked follows it */
	MLG_RETIRE_CLIENTS     = 3, /* other session clients attached (no MLG_RETIRE_FORCE) */
	MLG_RETIRE_RAW_BAR     = 4, /* a client maps a BAR: a close now would quarantine */
	MLG_RETIRE_QUARANTINED = 5, /* quarantined and not releasable now */
	MLG_RETIRE_STOPPING    = 6, /* IOKit is already stopping this instance */
	MLG_RETIRE_RESUMED     = 7, /* RESUME: sessions admitted again */
};

static inline bool mlg_retire_args_valid(const uint64_t *input, uint32_t input_count)
{
	return input && input_count == 3 && input[0] <= MLG_RETIRE_OP_DISCONNECT &&
	       !(input[1] & ~(uint64_t)MLG_RETIRE_FORCE) && input[2] == MLG_RETIRE_CONFIRM;
}

/* SysfsRead: the amdgpu device's sysfs directory, read as Linux sysfs reads
 * it (the attribute's show(), or a bin_attribute's read()), or listed.
 *   scalar in:  [0] MLG_SYSFS_OP_*, [1] byte offset into the file/listing
 *   struct in:  path relative to the device directory, e.g.
 *               "gpu_metrics", "hwmon/hwmon0/temp1_input"; 1 to
 *               MLG_SYSFS_PATH_MAX bytes, '/'-separated, no empty, "." or
 *               ".." component; one trailing NUL is allowed. A listing
 *               may pass no path: the device directory itself
 *   struct out: at most MLG_SYSFS_CHUNK_MAX bytes from the offset
 *   scalar out: [0] 0 or a negative Linux errno, sign-extended (show()'s
 *               own error, ENOENT, ENOTDIR, EISDIR, EACCES, ...)
 *               [1] bytes returned
 *               [2] full length: show()'s count, the bin file's size or
 *               the listing's size (read again at an offset for more)
 * A listing is "<type> <name>\n" per entry, sorted, type f (file),
 * d (directory) or l (link). Each call runs show() afresh.
 * IOReturn: NotReady unless the upstream driver runs in an open,
 * unquarantined session; BadArgument for a malformed call.
 *
 * DrmInfo: one DRM_IOCTL_AMDGPU_INFO on a render-node file the driver holds
 * for observers, through upstream amdgpu_info_ioctl.
 *   scalar in:  [0] query (AMDGPU_INFO_SENSOR, _VRAM_USAGE, _VIS_VRAM_USAGE,
 *               _GTT_USAGE, _VRAM_GTT, _MEMORY, _DEV_INFO or _READ_MMR_REG)
 *               [1] return_size, 1 to MLG_SYSFS_CHUNK_MAX
 *   struct in:  the request's argument union (sensor_info, read_mmr_reg),
 *               at most 16 bytes, or none
 *   struct out: return_size bytes of the result
 *   scalar out: [0] 0 or the ioctl's negative Linux errno, sign-extended
 * IOReturn as SysfsRead; NotPermitted for any other query. */
/* DrmSelfTest: the kernel-queue command submission self-test
 * (linuxu/headers/rt/cs_selftest.h) on the GPU, in a Linux process of its
 * own: render node, AMDGPU_INFO, a context, GEM buffers mapped in its own
 * GPUVM, AMDGPU_CS on the compute ring and on SDMA, AMDGPU_WAIT_CS and
 * syncobj waits, its VRAM buffer moved to GTT (through a GART transfer
 * window, as TTM evicts) and back by submissions, then everything undone. It touches nothing of any other
 * client and creates no queue; each wait is bounded.
 *   scalar in:  [0] MLG_DRM_SELFTEST_CONFIRM
 *   struct out: struct rt_cs_selftest_result (MLG_DRM_SELFTEST_RESULT_MAX
 *               bytes at most; its version and steps fields describe it)
 *   scalar out: [0] 0 or the first failing step's status, sign-extended
 *               (a negative Linux errno, RT_CS_MISMATCH, RT_CS_PARKED)
 *               [1] earlier tests still waiting for their GPU work
 * A test whose work never completed keeps its process until the work
 * does (RT_CS_PARKED); the session then cannot close cleanly until it
 * has. IOReturn as DrmInfo; Busy while another test runs. */
/* Display: the in-driver display test (linuxu/headers/rt/display.h), an
 * in-kernel DRM client on the GPU's own outputs. It requires display to be
 * on (personality MacLinuxGPUDisplay=true); otherwise every op returns
 * -ENODEV. One op at a time.
 *   scalar in:  [0] MLG_DISPLAY_OP_*
 *               [1] pattern for SHOW (MLG_DISPLAY_PATTERN_*), else 0
 *               [2] MLG_DISPLAY_CONFIRM
 *   struct in:  SHOW: optional connector name ("DP-1" or "card0-DP-1"), at
 *               most MLG_DISPLAY_NAME_MAX bytes with an optional trailing
 *               NUL; none means every connected output. MODES: required.
 *   struct out: struct rt_display_report, or for MODES struct
 *               rt_display_modes (MLG_DISPLAY_REPORT_MAX at most; the
 *               version field describes it)
 *   scalar out: [0] 0 or the op's negative Linux errno, sign-extended
 * PROBE runs each connector's detect and mode probe and commits nothing.
 * STATUS reads cached connector state with no detection and the hotplug
 * epoch (a display agent polls it and probes when it changes). MODES lists
 * one connector's probed modes.
 * SHOW records the current configuration, then commits the pattern at
 * each output's preferred mode; a failure restores what was recorded and
 * reports the failing step's errno (no other mechanism is tried). OFF
 * commits the recorded configuration again and frees everything. A
 * session close turns a showing pattern off before the driver is removed.
 * IOReturn as DrmInfo; Busy while another display op runs. */
#define MLG_DISPLAY_OP_PROBE    0u
#define MLG_DISPLAY_OP_SHOW     1u
#define MLG_DISPLAY_OP_OFF      2u
#define MLG_DISPLAY_OP_STATUS   3u
#define MLG_DISPLAY_OP_MODES    4u
/* A display agent's frames (docs/macos-displays.md). Imports belong to the
 * client that made them: its Stop releases them, as a session close
 * releases all; an output the client started is turned off with it.
 *   IMPORT  [1] width << 48 | height << 32 | pitch (bytes per row)
 *           struct in: the surface's memory (above 4096 bytes, so a memory
 *           descriptor), whole 16 KiB pages; it is mapped for the GPU
 *           (dext_dma_import) and imported (rt_surface_import)
 *           scalar out [1] the handle; no struct out
 *   VERIFY  [1] handle << 32 | seed: the GPU (SDMA) and a CPU view check
 *           the surface against rt_surface_pattern(seed)
 *           struct out: struct rt_surface_verify_result
 *   RELEASE [1] handle
 *   OUTPUT  [1] refresh in mHz; struct in: struct mlg_display_output; the
 *           connector at that mode with three framebuffers and a worker
 *           that copies and flips (rt_display_output)
 *           struct out: struct rt_display_report
 *   PRESENT [1] handle; struct in: struct mlg_display_present; queues the
 *           frame (its dirty rectangles, rows that scrolled and capture
 *           time) for the worker
 *           and returns without waiting for the copy or the flip
 *           (rt_display_present); no rectangle only reads the statistics
 *           struct out: struct rt_display_present_stats (version 3) */
#define MLG_DISPLAY_OP_IMPORT   5u
#define MLG_DISPLAY_OP_VERIFY   6u
#define MLG_DISPLAY_OP_RELEASE  7u
#define MLG_DISPLAY_OP_OUTPUT   8u
#define MLG_DISPLAY_OP_PRESENT  9u
/* Every op but PRESENT can sleep (a probe's AUX transfers, allocations,
 * evictions, fence waits, a modeset), so none runs on the call: the call
 * must carry an async completion (IOConnectCallAsyncMethod), returns at
 * once with out[0] = 0 and out[1] = a token, and the op runs on a driver
 * thread (rt_wait_pool). A synchronous call of one is refused
 * (kIOReturnBadArgument); one while another runs is kIOReturnBusy. The
 * completion's async data: [0] token, [1] the op's IOReturn, [2] its out[0]
 * (status), [3] its out[1] (IMPORT's handle), [4] bytes of its structure
 * output, which
 *   RESULT  [1] token: returns, once, as struct out (with out[0] and out[1]
 *           again); the client's last op's result only.
 * PRESENT never sleeps (rt_display_present): it is a synchronous call, and
 * returns -EBUSY in out[0] while an op that can sleep holds the display. */
#define MLG_DISPLAY_OP_RESULT   10u
#define MLG_DISPLAY_ASYNC_WORDS 5u
#define MLG_DISPLAY_PRESENT_RECTS_MAX 255u

struct mlg_display_output {
	char connector[32];
	uint32_t width, height;
};

struct mlg_display_rect {
	uint32_t x, y, width, height;
};

/* Rows that scrolled (rt_display_move): width x height at (x, y) are the
 * previous frame's pixels at (x, src_y). */
struct mlg_display_move {
	uint32_t x, y, width, height;
	uint32_t src_y;
	uint32_t reserved; /* 0 */
};
#define MLG_DISPLAY_PRESENT_MOVES_MAX 32u

struct mlg_display_present {
	uint32_t count;
	uint32_t moves; /* struct mlg_display_move after the rectangles; 0 before build 240 */
	uint64_t capture_ns; /* when the frame was captured, mach_absolute_time in ns */
	struct mlg_display_rect rect[]; /* count, at most MLG_DISPLAY_PRESENT_RECTS_MAX, then the
					 * moves; the request at most MLG_DISPLAY_PRESENT_BYTES_MAX */
};
#define MLG_DISPLAY_PRESENT_BYTES_MAX 4096u /* an inline structure input */
#define MLG_DISPLAY_PATTERN_BARS     0u
#define MLG_DISPLAY_PATTERN_WHITE    1u
#define MLG_DISPLAY_PATTERN_GRADIENT 2u
#define MLG_DISPLAY_PATTERNS    3u
#define MLG_DISPLAY_CONFIRM     0x44495350ULL /* "DISP" */
#define MLG_DISPLAY_NAME_MAX    31u
#define MLG_DISPLAY_WORDS       2u /* [0] status; [1] IMPORT's handle */
#define MLG_DISPLAY_REPORT_MAX  1024u

#define MLG_DRM_SELFTEST_CONFIRM    0x43535354ULL /* "CSST" */
#define MLG_DRM_SELFTEST_WORDS      2u
#define MLG_DRM_SELFTEST_RESULT_MAX 512u

/* QueryInfo tag 8: the device spec, as a structure output (struct
 * mlg_device_spec; through OWNER_RESULT for an async call), out[0] its
 * size. Every field is upstream's own: the GC geometry and the CUs, shader
 * arrays and render backends it left active (adev->gfx.config, cu_info,
 * the KFD node's properties), and, on GC 12, the shader-array disable
 * registers it reads (read only; no register is written). A field group
 * not set in @present was not reported. Clients size their buffer to the
 * struct they know and read @size of it; later versions only append. */
#define MLG_QUERY_DEVICE_SPEC		8u
#define MLG_DEVICE_SPEC_VERSION		1u
#define MLG_DEVICE_SPEC_GEOMETRY	(1u << 0) /* shader_engines .. lds_bytes */
#define MLG_DEVICE_SPEC_CUS		(1u << 1) /* active_cus, cu_bitmap */
#define MLG_DEVICE_SPEC_SHADER_ARRAYS	(1u << 2) /* active_sa_bitmap */
#define MLG_DEVICE_SPEC_SA_DISABLE	(1u << 3) /* cc_sa_disable, user_sa_disable */
#define MLG_DEVICE_SPEC_BACKENDS	(1u << 4) /* active_rb_bitmap, active_rbs */
struct mlg_device_spec {
	uint32_t version;		/* MLG_DEVICE_SPEC_VERSION */
	uint32_t size;			/* bytes of this struct the driver filled */
	uint32_t present;		/* MLG_DEVICE_SPEC_* */
	uint32_t reserved;
	uint32_t shader_engines, shader_arrays_per_se, backends_per_se, cus_per_array;
	uint32_t wavefront_size, max_waves_per_simd, scratch_slots_per_cu, lds_bytes;
	uint32_t active_cus;
	uint32_t cu_bitmap[4][4];	/* [shader engine][shader array], as KFD's */
	uint32_t active_sa_bitmap;	/* bit se * arrays_per_se + sa */
	uint32_t cc_sa_disable, user_sa_disable; /* GRBM_CC/GC_USER_SA_UNIT_DISABLE, raw */
	uint32_t active_rb_bitmap, active_rbs;
};

#define MLG_SYSFS_OP_READ      0u
#define MLG_SYSFS_OP_LIST      1u
#define MLG_SYSFS_PATH_MAX     256u
#define MLG_SYSFS_CHUNK_MAX    4096u
#define MLG_SYSFS_READ_WORDS   3u
#define MLG_DRM_INFO_ARGS_MAX  16u

#define MLG_QUERY_PROBE_STATUS  0x4c50524fULL /* "LPRO" */
#define MLG_QUERY_KERNEL_LOG    0x4c4c4f47ULL /* "LLOG" */
#define MLG_QUERY_SESSION_STATE 0x4c534553ULL /* "LSES" */
/* GPU recovery (linuxu/headers/rt/recovery.h), cached, never blocking:
 *   out[0] layout version (MLG_RESET_STATE_VERSION)
 *   out[1] reset generation: queue resets that succeeded, device resets,
 *          and the wedge, each one step
 *   out[2] MLG_RESET_FLAG_*
 *   out[3] queue resets that succeeded
 *   out[4] upstream's VRAM-lost counter
 *   out[5] the last reset's result (0, or a negative Linux errno) */
#define MLG_QUERY_RESET_STATE   0x4c525354ULL /* "LRST" */
#define MLG_RESET_STATE_VERSION 1u
#define MLG_RESET_STATE_WORDS   6u
#define MLG_RESET_FLAG_WEDGED          (1u << 0) /* power-cycle the GPU */
#define MLG_RESET_FLAG_LAST_VRAM_LOST  (1u << 1)

/* Entitlement a client must hold to release a quarantined session. */
#define MLG_SESSION_RELEASE_ENTITLEMENT "com.geramyloveless.MacAMDGPUHost.session-release"

/* SysfsRead's path argument: copy @length bytes (one trailing NUL allowed)
 * into @path as a C string if they form a relative sysfs path of at most
 * MLG_SYSFS_PATH_MAX bytes with no empty, "." or ".." component. With
 * @directory, no bytes at all name the device directory itself. */
static inline bool mlg_sysfs_path_copy(char path[MLG_SYSFS_PATH_MAX + 1],
				       const char *bytes, size_t length, bool directory)
{
	if (bytes && length && bytes[length - 1] == '\0')
		--length;
	if (directory && (!bytes || !length)) {
		path[0] = '\0';
		return true;
	}
	if (!bytes || !length || length > MLG_SYSFS_PATH_MAX)
		return false;
	size_t start = 0;
	for (size_t i = 0; i <= length; ++i) {
		if (i < length && bytes[i] == '\0')
			return false;
		if (i < length && bytes[i] != '/')
			continue;
		const size_t n = i - start;
		if (!n || (n == 1 && bytes[start] == '.') ||
		    (n == 2 && bytes[start] == '.' && bytes[start + 1] == '.'))
			return false;
		start = i + 1;
	}
	for (size_t i = 0; i < length; ++i)
		path[i] = bytes[i];
	path[length] = '\0';
	return true;
}

static inline bool mlg_observer_selector_allowed(uint64_t selector,
						 const uint64_t *input,
						 uint32_t input_count)
{
	switch (selector) {
	case MLG_SELECTOR_PING:
	case MLG_SELECTOR_RUNTIME_BUILD:
	case MLG_SELECTOR_RELEASE_QUARANTINE:
		return true;
	case MLG_SELECTOR_OWNER_RESULT:
		return input && input_count == 1 && input[0];
	case MLG_SELECTOR_RETIRE: /* entitlement-checked in the handler */
		return mlg_retire_args_valid(input, input_count);
	case MLG_SELECTOR_QUERY_INFO:
		if (!input || !input_count)
			return false;
		return (input[0] == MLG_QUERY_PROBE_STATUS && input_count == 1) ||
		       (input[0] == MLG_QUERY_SESSION_STATE && input_count == 1) ||
		       (input[0] == MLG_QUERY_POWER_STATE && input_count == 1) ||
		       (input[0] == MLG_QUERY_RESET_STATE && input_count == 1) ||
		       (input[0] == MLG_QUERY_KERNEL_LOG && input_count == 2);
	case MLG_SELECTOR_SYSFS_READ:
		return input && input_count == 2 &&
		       (input[0] == MLG_SYSFS_OP_READ || input[0] == MLG_SYSFS_OP_LIST);
	case MLG_SELECTOR_DRM_INFO:
		return input && input_count == 2 && input[1] &&
		       input[1] <= MLG_SYSFS_CHUNK_MAX;
	case MLG_SELECTOR_DRM_SELFTEST:
		return input && input_count == 1 && input[0] == MLG_DRM_SELFTEST_CONFIRM;
	case MLG_SELECTOR_DISPLAY:
		if (!input || input_count != 3 || input[2] != MLG_DISPLAY_CONFIRM)
			return false;
		switch (input[0]) {
		case MLG_DISPLAY_OP_SHOW:
			return input[1] < MLG_DISPLAY_PATTERNS;
		case MLG_DISPLAY_OP_PROBE:
		case MLG_DISPLAY_OP_OFF:
		case MLG_DISPLAY_OP_STATUS:
		case MLG_DISPLAY_OP_MODES:
			return !input[1];
		case MLG_DISPLAY_OP_IMPORT:
			return (input[1] >> 48) && ((input[1] >> 32) & 0xffff) && (uint32_t)input[1];
		case MLG_DISPLAY_OP_VERIFY:
			return (input[1] >> 32) != 0;
		case MLG_DISPLAY_OP_RELEASE:
			return input[1] && input[1] <= UINT32_MAX;
		case MLG_DISPLAY_OP_PRESENT:
			/* Handle 0 with no rectangle reads the statistics. */
			return input[1] <= UINT32_MAX;
		case MLG_DISPLAY_OP_RESULT:
			return input[1] != 0;
		case MLG_DISPLAY_OP_OUTPUT:
			return input[1] && input[1] <= 1000000;
		default:
			return false;
		}
	case MLG_SELECTOR_POWER:
		/* QUERY and WAIT; PREPARE/RESUME check the release entitlement. */
		return input && input_count >= 1 && input_count <= 2 && input[0] <= MLG_POWER_OP_WAIT;
	default:
		return false;
	}
}

/* Whether a call of @selector with @input runs on the delivery thread
 * itself (above): Ping, RuntimeBuild (its cached answer), the cached
 * QueryInfo tags, the power query and the power wait's registration, and
 * OWNER_RESULT. They read state the session queue publishes, or take only
 * a spinlock. */
static inline bool mlg_call_runs_on_delivery(uint64_t selector, const uint64_t *input,
					     uint32_t input_count)
{
	switch (selector) {
	case MLG_SELECTOR_PING:
	case MLG_SELECTOR_RUNTIME_BUILD:
		return true;
	case MLG_SELECTOR_OWNER_RESULT:
		return input && input_count == 1 && input[0];
	case MLG_SELECTOR_QUERY_INFO:
		if (!input || !input_count)
			return false;
		return (input[0] == MLG_QUERY_PROBE_STATUS && input_count == 1) ||
		       (input[0] == MLG_QUERY_SESSION_STATE && input_count == 1) ||
		       (input[0] == MLG_QUERY_POWER_STATE && input_count == 1) ||
		       (input[0] == MLG_QUERY_RESET_STATE && input_count == 1) ||
		       (input[0] == MLG_QUERY_KERNEL_LOG && input_count == 2);
	case MLG_SELECTOR_POWER:
		return input && input_count >= 1 &&
		       (input[0] == MLG_POWER_OP_QUERY || input[0] == MLG_POWER_OP_WAIT);
	default:
		return false;
	}
}

/* The Linux-file client's own selectors (linuxu/headers/rt/lx_abi.h,
 * MLG_SELECTOR_LX_FIRST..LAST), answered on the call (the delivery
 * thread): synchronous (LX_IOCTL, LX_RESULT, LX_MMAP_COMMIT, LX_SCANOUT and
 * the retired ones), except LX_IOCTL_ASYNC and LX_CALL_ASYNC, which carry
 * their own completion (never OWNER_RESULT's). test-selector-call checks
 * the numbers. */
#define MLG_CALL_LX_FIRST		96u
#define MLG_CALL_LX_IOCTL_ASYNC		99u
#define MLG_CALL_LX_CALL_ASYNC		105u
#define MLG_CALL_LX_LAST		105u

/* Whether a client calls @selector with @input synchronously: those that
 * run on the delivery thread, the Linux-file client's synchronous ones,
 * the bounded reads (SysfsRead, DrmInfo), and the display's PRESENT and
 * RESULT. Every other call is async. */
static inline bool mlg_call_is_synchronous(uint64_t selector, const uint64_t *input,
					   uint32_t input_count)
{
	if (mlg_call_runs_on_delivery(selector, input, input_count))
		return true;
	if (selector >= MLG_CALL_LX_FIRST && selector <= MLG_CALL_LX_LAST)
		return selector != MLG_CALL_LX_IOCTL_ASYNC && selector != MLG_CALL_LX_CALL_ASYNC;
	if (selector == MLG_SELECTOR_SYSFS_READ || selector == MLG_SELECTOR_DRM_INFO)
		return true;
	return selector == MLG_SELECTOR_DISPLAY && input && input_count >= 1 &&
	       (input[0] == MLG_DISPLAY_OP_PRESENT || input[0] == MLG_DISPLAY_OP_RESULT);
}

#endif
