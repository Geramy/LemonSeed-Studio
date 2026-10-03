// Minimal WASI preview 1 for running a command module in WebKit.
//
// Supported: args, environ, clocks, random, stdout/stderr (streamed to the
// app), stdin at end of file, proc_exit. There is no file system yet: no
// preopens are offered, so path_open is never reached by well-behaved libc
// code. Anything else returns ENOSYS.
//
// Output is sent to the app with window.webkit.messageHandlers.lsx. Those
// messages travel over IPC even while the module runs synchronously on this
// thread, so output streams during long runs.

"use strict";

(function () {
  const ERRNO = { SUCCESS: 0, BADF: 8, INVAL: 28, NOSYS: 52, SPIPE: 70, NOTCAPABLE: 76 };
  const FILETYPE_CHARACTER_DEVICE = 2;
  const CLOCK = { REALTIME: 0, MONOTONIC: 1, PROCESS_CPUTIME: 2, THREAD_CPUTIME: 3 };

  const post = (message) => window.webkit.messageHandlers.lsx.postMessage(message);

  class ProcExit extends Error {
    constructor(code) { super("proc_exit(" + code + ")"); this.code = code; }
  }

  // Buffers stdout/stderr and flushes on size or time, so printf-heavy
  // programs do not send one IPC message per write.
  class OutputPipe {
    constructor(runId, fd) {
      this.runId = runId; this.fd = fd;
      this.decoder = new TextDecoder("utf-8");
      this.pending = ""; this.lastFlush = performance.now();
    }
    write(bytes) {
      this.pending += this.decoder.decode(bytes, { stream: true });
      const now = performance.now();
      if (this.pending.length > 16384 || now - this.lastFlush > 33) this.flush(now);
    }
    flush(now) {
      this.pending += this.decoder.decode();
      if (this.pending.length) post({ type: "output", id: this.runId, fd: this.fd, text: this.pending });
      this.pending = ""; this.lastFlush = now || performance.now();
    }
  }

  function encodeStrings(list) {
    const encoder = new TextEncoder();
    return list.map((s) => { const b = encoder.encode(s); const z = new Uint8Array(b.length + 1); z.set(b); return z; });
  }

  function makeWASI(config, getMemory) {
    const args = encodeStrings(config.args || []);
    const env = encodeStrings(Object.entries(config.env || {}).map(([k, v]) => k + "=" + v));
    const pipes = { 1: new OutputPipe(config.id, 1), 2: new OutputPipe(config.id, 2) };
    const view = () => new DataView(getMemory().buffer);
    const bytes = () => new Uint8Array(getMemory().buffer);
    const unsupported = new Set();

    function putList(list, ptrs, buf) {
      const dv = view(), mem = bytes();
      for (const item of list) {
        dv.setUint32(ptrs, buf, true); ptrs += 4;
        mem.set(item, buf); buf += item.length;
      }
      return ERRNO.SUCCESS;
    }
    function putSizes(list, countPtr, sizePtr) {
      const dv = view();
      dv.setUint32(countPtr, list.length, true);
      dv.setUint32(sizePtr, list.reduce((n, b) => n + b.length, 0), true);
      return ERRNO.SUCCESS;
    }
    function nowNanos(id) {
      if (id === CLOCK.REALTIME) return BigInt(Date.now()) * 1000000n;
      // performance.now() is fine-grained enough for timing user code.
      return BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));
    }

    const imports = {
      args_get: (argv, buf) => putList(args, argv, buf),
      args_sizes_get: (count, size) => putSizes(args, count, size),
      environ_get: (envp, buf) => putList(env, envp, buf),
      environ_sizes_get: (count, size) => putSizes(env, count, size),
      clock_res_get: (id, out) => { view().setBigUint64(out, 1000n, true); return ERRNO.SUCCESS; },
      clock_time_get: (id, _precision, out) => {
        if (id > CLOCK.THREAD_CPUTIME) return ERRNO.INVAL;
        view().setBigUint64(out, nowNanos(id), true);
        return ERRNO.SUCCESS;
      },
      random_get: (buf, len) => {
        const mem = bytes();
        for (let off = 0; off < len; off += 65536) {
          crypto.getRandomValues(mem.subarray(buf + off, buf + Math.min(len, off + 65536)));
        }
        return ERRNO.SUCCESS;
      },
      fd_write: (fd, iovs, iovsLen, nwritten) => {
        const pipe = pipes[fd];
        if (!pipe) return ERRNO.BADF;
        const dv = view(), mem = bytes();
        let total = 0;
        for (let i = 0; i < iovsLen; i++) {
          const ptr = dv.getUint32(iovs + i * 8, true);
          const len = dv.getUint32(iovs + i * 8 + 4, true);
          if (len) pipe.write(mem.slice(ptr, ptr + len));
          total += len;
        }
        dv.setUint32(nwritten, total, true);
        return ERRNO.SUCCESS;
      },
      fd_read: (fd, _iovs, _iovsLen, nread) => {
        if (fd !== 0) return ERRNO.BADF;
        view().setUint32(nread, 0, true); // stdin is at end of file
        return ERRNO.SUCCESS;
      },
      fd_fdstat_get: (fd, out) => {
        if (fd > 2) return ERRNO.BADF;
        const dv = view();
        dv.setUint8(out, FILETYPE_CHARACTER_DEVICE);
        dv.setUint16(out + 2, 0, true);
        dv.setBigUint64(out + 8, 0xffffffffn, true);
        dv.setBigUint64(out + 16, 0n, true);
        return ERRNO.SUCCESS;
      },
      fd_fdstat_set_flags: (fd) => (fd <= 2 ? ERRNO.SUCCESS : ERRNO.BADF),
      fd_filestat_get: (fd, out) => {
        if (fd > 2) return ERRNO.BADF;
        const mem = bytes();
        mem.fill(0, out, out + 64);
        view().setUint8(out + 16, FILETYPE_CHARACTER_DEVICE);
        return ERRNO.SUCCESS;
      },
      fd_seek: (fd) => (fd <= 2 ? ERRNO.SPIPE : ERRNO.BADF),
      fd_close: (fd) => (fd <= 2 ? ERRNO.SUCCESS : ERRNO.BADF),
      fd_sync: () => ERRNO.SUCCESS,
      fd_prestat_get: () => ERRNO.BADF, // no preopened directories
      fd_prestat_dir_name: () => ERRNO.BADF,
      path_open: () => ERRNO.NOTCAPABLE,
      sched_yield: () => ERRNO.SUCCESS,
      proc_exit: (code) => { throw new ProcExit(code); },
      proc_raise: () => ERRNO.NOSYS,
    };

    // Unknown imports resolve to an ENOSYS stub instead of failing instantiation.
    const module = new Proxy(imports, {
      get(target, name) {
        if (name in target) return target[name];
        return () => { unsupported.add(String(name)); return ERRNO.NOSYS; };
      },
    });
    return { module, pipes, unsupported };
  }

  async function run(config) {
    const t = { start: performance.now() };
    let instance = null;
    const wasi = makeWASI(config, () => instance.exports.memory);
    let exitCode = 0, error = null;
    try {
      const response = await fetch(config.programURL);
      if (!response.ok) throw new Error("could not load the program (" + response.status + ")");
      const buffer = await response.arrayBuffer();
      t.fetched = performance.now();
      const module = await WebAssembly.compile(buffer);
      t.compiled = performance.now();
      instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.module });
      t.instantiated = performance.now();
      try {
        instance.exports._start();
      } catch (e) {
        if (e instanceof ProcExit) exitCode = e.code;
        else throw e;
      }
    } catch (e) {
      exitCode = -1;
      error = String(e && e.stack ? e.message + "\n" + e.stack : e);
    }
    t.finished = performance.now();
    wasi.pipes[1].flush(); wasi.pipes[2].flush();
    post({
      type: "exit", id: config.id, code: exitCode, error,
      unsupported: Array.from(wasi.unsupported),
      fetchMs: (t.fetched || t.finished) - t.start,
      compileMs: t.compiled ? t.compiled - t.fetched : 0,
      instantiateMs: t.instantiated ? t.instantiated - t.compiled : 0,
      runMs: t.instantiated ? t.finished - t.instantiated : 0,
    });
  }

  window.lsxRun = (config) => { run(config); return true; };
})();
