// WASIX (wasix_32v1) on WAMR. See include/lst_wasix.h.
//
// WAMR runs WASI preview 1 natively, plus its own socket extension, both in
// libc-wasi, and wasi-threads. WASIX programs (wasix-libc) import preview 1
// for files and streams, wasi.thread-spawn for threads, and wasix_32v1 for
// the rest. This file implements wasix_32v1:
//
// - Sockets translate WASIX's address and option ABI into calls to WAMR's
//   own socket natives (looked up in get_libc_wasi_export_apis), so a socket
//   is a WASI descriptor in WAMR's table and every preview 1 call works on it.
// - Futexes are a hash table of condition variables keyed by address.
// - thread_exit and thread_id use two functions patched into WAMR's
//   wasi-threads (patches/wamr/0001), so a thread ends without ending the
//   others and its id is recycled.
// - Signals raised by the program (raise, pthread_kill to itself) call the
//   handler entry point the program registers with callback_signal.
// - The working directory is the program's own record ("/" at start).
//
// Every other wasix_32v1 call (fork, exec, spawn, dlopen, closures, stack
// checkpoints, epoll, pipes, dup, networking ports) answers ENOSYS; see
// lst_wasix_coverage().

#include "lst_wasix.h"

#include <lemonseed/wamr_config.h>

#if LST_HAVE_WAMR

#include <wamr/wasm_export.h>

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// From patches/wamr/0001 (WAMR's lib_wasi_threads_wrapper.c).
int32_t lst_wasi_threads_current_id(wasm_exec_env_t exec_env);
bool lst_wasi_threads_exit_current(wasm_exec_env_t exec_env);
// WAMR's libc-wasi natives (libc_wasi_wrapper.c).
uint32_t get_libc_wasi_export_apis(NativeSymbol **apis);

// WASI errno values (the same in preview 1 and WASIX).
enum {
  E_SUCCESS = 0, E_AFNOSUPPORT = 5, E_BADF = 8, E_FAULT = 21, E_INVAL = 28, E_NAMETOOLONG = 37,
  E_NOMEM = 48, E_NOPROTOOPT = 50, E_NOSYS = 52, E_RANGE = 68, E_TIMEDOUT = 73,
};

// --- WAMR's socket ABI (platform_wasi_types.h) -------------------------------

typedef enum { W_IPV4 = 0, W_IPV6 = 1 } w_addr_type;
typedef struct { uint8_t n0, n1, n2, n3; } w_ip4;
typedef struct { w_ip4 addr; uint16_t port; } w_ip4_port;
typedef struct { uint16_t s[8]; } w_ip6;
typedef struct { w_ip6 addr; uint16_t port; } w_ip6_port;
typedef struct {
  w_addr_type kind;
  union { w_ip4_port ip4; w_ip6_port ip6; } addr;
} w_addr;
typedef struct { w_addr addr; int type; } w_addr_info;
typedef struct { int type; int family; uint8_t hints_enabled; } w_hints;
enum { W_INET4 = 0, W_INET6 = 1, W_INET_UNSPEC = 2 };
enum { W_SOCKET_ANY = -1, W_SOCKET_DGRAM = 0, W_SOCKET_STREAM = 1 };

// --- WASIX's ABI (wasix-libc api_wasix.h, wasm32) ---------------------------

enum { X_AF_UNSPEC = 0, X_AF_INET4 = 1, X_AF_INET6 = 2, X_AF_UNIX = 3 };
enum { X_SOCK_STREAM = 1, X_SOCK_DGRAM = 2 };
enum {
  X_OPT_REUSE_PORT = 1, X_OPT_REUSE_ADDR = 2, X_OPT_NO_DELAY = 3, X_OPT_ONLY_V6 = 5,
  X_OPT_BROADCAST = 6, X_OPT_KEEP_ALIVE = 12, X_OPT_LINGER = 13, X_OPT_RECV_BUF_SIZE = 15,
  X_OPT_SEND_BUF_SIZE = 16, X_OPT_RECV_TIMEOUT = 19, X_OPT_SEND_TIMEOUT = 20, X_OPT_TTL = 23,
};
enum { X_SOCK_STATUS_OPENED = 1 };
// __wasi_addr_port_t: tag at 0; port (u16) at 2; then the address at 4:
// 4 bytes (ip4, network order) or 8 u16 segments (ip6). 110 bytes in all.
#define X_ADDR_PORT_SIZE 110
// __wasi_addr_ip_t: tag at 0; the address at 2. 18 bytes.
#define X_ADDR_IP_SIZE 18
// __wasi_option_timestamp_t: tag at 0, u64 at 8. 16 bytes.
#define X_OPTION_TS_SIZE 16
// __wasi_tty_t: 24 bytes.
#define X_TTY_SIZE 24

// --- WAMR's natives, by name ------------------------------------------------

typedef uint32_t (*fn_sock_open)(wasm_exec_env_t, uint32_t, int, int, uint32_t *);
typedef uint32_t (*fn_sock_addr)(wasm_exec_env_t, uint32_t, w_addr *);
typedef uint32_t (*fn_sock_listen)(wasm_exec_env_t, uint32_t, uint32_t);
typedef uint32_t (*fn_sock_accept)(wasm_exec_env_t, uint32_t, uint16_t, uint32_t *);
typedef uint32_t (*fn_sock_resolve)(wasm_exec_env_t, const char *, const char *, w_hints *, w_addr_info *,
                                    uint32_t, uint32_t *);
typedef uint32_t (*fn_sock_recv_from)(wasm_exec_env_t, uint32_t, void *, uint32_t, uint16_t, w_addr *,
                                      uint32_t *);
typedef uint32_t (*fn_sock_send_to)(wasm_exec_env_t, uint32_t, const void *, uint32_t, uint16_t,
                                    const w_addr *, uint32_t *);
typedef uint32_t (*fn_sock_set_bool)(wasm_exec_env_t, uint32_t, bool);
typedef uint32_t (*fn_sock_get_bool)(wasm_exec_env_t, uint32_t, bool *);
typedef uint32_t (*fn_sock_set_size)(wasm_exec_env_t, uint32_t, size_t);
typedef uint32_t (*fn_sock_get_size)(wasm_exec_env_t, uint32_t, size_t *);
typedef uint32_t (*fn_sock_set_time)(wasm_exec_env_t, uint32_t, uint64_t);
typedef uint32_t (*fn_sock_get_time)(wasm_exec_env_t, uint32_t, uint64_t *);
typedef uint32_t (*fn_sock_set_linger)(wasm_exec_env_t, uint32_t, bool, int);
typedef uint32_t (*fn_sock_get_linger)(wasm_exec_env_t, uint32_t, bool *, int *);
typedef uint32_t (*fn_sock_set_ttl)(wasm_exec_env_t, uint32_t, uint8_t);
typedef uint32_t (*fn_path_open)(wasm_exec_env_t, uint32_t, uint32_t, const char *, uint32_t, uint16_t, uint64_t,
                                 uint64_t, uint16_t, uint32_t *);
typedef void (*fn_proc_exit)(wasm_exec_env_t, uint32_t);

static struct {
  fn_sock_open sock_open;
  fn_sock_addr sock_bind, sock_connect, sock_addr_local, sock_addr_remote;
  fn_sock_listen sock_listen;
  fn_sock_accept sock_accept;
  fn_sock_resolve sock_addr_resolve;
  fn_sock_recv_from sock_recv_from;
  fn_sock_send_to sock_send_to;
  fn_sock_set_bool set_reuse_addr, set_reuse_port, set_tcp_no_delay, set_keep_alive, set_broadcast, set_ipv6_only;
  fn_sock_get_bool get_reuse_addr, get_reuse_port, get_tcp_no_delay, get_keep_alive, get_broadcast, get_ipv6_only;
  fn_sock_set_size set_recv_buf_size, set_send_buf_size;
  fn_sock_get_size get_recv_buf_size, get_send_buf_size;
  fn_sock_set_time set_recv_timeout, set_send_timeout;
  fn_sock_get_time get_recv_timeout, get_send_timeout;
  fn_sock_set_linger set_linger;
  fn_sock_get_linger get_linger;
  fn_sock_set_ttl set_ip_ttl;
  fn_path_open path_open;
  fn_proc_exit proc_exit;
} W;

static void *find_native(NativeSymbol *apis, uint32_t count, const char *name) {
  for (uint32_t i = 0; i < count; i++)
    if (strcmp(apis[i].symbol, name) == 0)
      return apis[i].func_ptr;
  return NULL;
}

// --- Per program: working directory and the signal entry point -------------

typedef struct {
  pthread_mutex_t lock;
  char cwd[1024];
  char signal_callback[128];
} program_state;

static pthread_mutex_t g_programs_lock = PTHREAD_MUTEX_INITIALIZER;

// Spawned threads' instances inherit the custom data of the instance that
// spawned them, so the state is shared by every thread of the program. It
// lives as long as the process: a few bytes per program run, left for the
// runtime's teardown order not to matter.
static program_state *state_of(wasm_module_inst_t inst) {
  pthread_mutex_lock(&g_programs_lock);
  program_state *s = wasm_runtime_get_custom_data(inst);
  if (!s) {
    s = calloc(1, sizeof *s);
    if (s) {
      pthread_mutex_init(&s->lock, NULL);
      strcpy(s->cwd, "/");
      wasm_runtime_set_custom_data(inst, s);
    }
  }
  pthread_mutex_unlock(&g_programs_lock);
  return s;
}

// --- Memory -----------------------------------------------------------------

static void *app(wasm_exec_env_t env, uint32_t offset, uint64_t size) {
  wasm_module_inst_t inst = wasm_runtime_get_module_inst(env);
  if (!wasm_runtime_validate_app_addr(inst, (uint64_t)offset, size))
    return NULL;
  return wasm_runtime_addr_app_to_native(inst, (uint64_t)offset);
}

static void put_u16(uint8_t *p, uint16_t v) { memcpy(p, &v, 2); }
static uint16_t get_u16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }
static void put_u32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void put_u64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static uint64_t get_u64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }

// --- Addresses --------------------------------------------------------------

static uint32_t addr_from_wasix(const uint8_t *x, w_addr *out) {
  memset(out, 0, sizeof *out);
  switch (x[0]) {
  case X_AF_INET4:
    out->kind = W_IPV4;
    out->addr.ip4.port = get_u16(x + 2);
    out->addr.ip4.addr.n0 = x[4];
    out->addr.ip4.addr.n1 = x[5];
    out->addr.ip4.addr.n2 = x[6];
    out->addr.ip4.addr.n3 = x[7];
    return E_SUCCESS;
  case X_AF_INET6:
    out->kind = W_IPV6;
    out->addr.ip6.port = get_u16(x + 2);
    for (int i = 0; i < 8; i++)
      out->addr.ip6.addr.s[i] = get_u16(x + 4 + 2 * i);
    return E_SUCCESS;
  default:
    return E_AFNOSUPPORT;
  }
}

static void addr_to_wasix(const w_addr *in, uint8_t *x) {
  memset(x, 0, X_ADDR_PORT_SIZE);
  if (in->kind == W_IPV4) {
    x[0] = X_AF_INET4;
    put_u16(x + 2, in->addr.ip4.port);
    x[4] = in->addr.ip4.addr.n0;
    x[5] = in->addr.ip4.addr.n1;
    x[6] = in->addr.ip4.addr.n2;
    x[7] = in->addr.ip4.addr.n3;
  } else {
    x[0] = X_AF_INET6;
    put_u16(x + 2, in->addr.ip6.port);
    for (int i = 0; i < 8; i++)
      put_u16(x + 4 + 2 * i, in->addr.ip6.addr.s[i]);
  }
}

// --- Sockets ----------------------------------------------------------------
//
// WAMR's socket natives check that every pointer they are given lies in the
// program's memory. So the WAMR-format structures are built in the program's
// own buffers: an address the program passes is converted in place for the
// call and restored after; an address WAMR returns is written into the
// program's output buffer and converted there. Both buffers are 110 bytes, a
// WAMR address 24.

_Static_assert(sizeof(w_addr) <= X_ADDR_PORT_SIZE, "a WAMR address fits a WASIX one");

// Converts the WASIX address at x to WAMR's format in place; `saved` keeps
// the original bytes for restore_addr.
static uint32_t stage_addr(uint8_t *x, uint8_t saved[X_ADDR_PORT_SIZE]) {
  memcpy(saved, x, X_ADDR_PORT_SIZE);
  w_addr a;
  uint32_t err = addr_from_wasix(saved, &a);
  if (err) return err;
  memcpy(x, &a, sizeof a);
  return E_SUCCESS;
}

static void restore_addr(uint8_t *x, const uint8_t saved[X_ADDR_PORT_SIZE]) {
  memcpy(x, saved, X_ADDR_PORT_SIZE);
}

// WAMR wrote its address format at x: rewrite it as WASIX's.
static void publish_addr(uint8_t *x) {
  w_addr a;
  memcpy(&a, x, sizeof a);
  addr_to_wasix(&a, x);
}

static uint32_t x_sock_open(wasm_exec_env_t env, uint32_t af, uint32_t type, uint32_t proto, uint32_t ret) {
  (void)proto;
  uint32_t *out = app(env, ret, 4);
  if (!out) return E_FAULT;
  int w_af = af == X_AF_INET4 ? W_INET4 : af == X_AF_INET6 ? W_INET6 : -1;
  int w_type = type == X_SOCK_STREAM ? W_SOCKET_STREAM : type == X_SOCK_DGRAM ? W_SOCKET_DGRAM : -1;
  if (w_af < 0) return E_AFNOSUPPORT;
  if (w_type < 0) return E_NOPROTOOPT;
  return W.sock_open(env, 0, w_af, w_type, out);
}

static uint32_t x_sock_bind_connect(wasm_exec_env_t env, uint32_t fd, uint32_t addr, bool bind) {
  uint8_t *x = app(env, addr, X_ADDR_PORT_SIZE);
  if (!x) return E_FAULT;
  uint8_t saved[X_ADDR_PORT_SIZE];
  uint32_t err = stage_addr(x, saved);
  if (err == E_SUCCESS)
    err = bind ? W.sock_bind(env, fd, (w_addr *)x) : W.sock_connect(env, fd, (w_addr *)x);
  restore_addr(x, saved);
  return err;
}

static uint32_t x_sock_bind(wasm_exec_env_t env, uint32_t fd, uint32_t addr) {
  return x_sock_bind_connect(env, fd, addr, true);
}

static uint32_t x_sock_connect(wasm_exec_env_t env, uint32_t fd, uint32_t addr) {
  return x_sock_bind_connect(env, fd, addr, false);
}

static uint32_t x_sock_listen(wasm_exec_env_t env, uint32_t fd, uint32_t backlog) {
  return W.sock_listen(env, fd, backlog);
}

static uint32_t x_sock_accept_v2(wasm_exec_env_t env, uint32_t fd, uint32_t flags, uint32_t ret_fd,
                                 uint32_t ret_addr) {
  uint32_t *out_fd = app(env, ret_fd, 4);
  uint8_t *out_addr = app(env, ret_addr, X_ADDR_PORT_SIZE);
  if (!out_fd || !out_addr) return E_FAULT;
  uint32_t err = W.sock_accept(env, fd, (uint16_t)flags, out_fd);
  if (err) return err;
  memset(out_addr, 0, X_ADDR_PORT_SIZE);
  if (W.sock_addr_remote(env, *out_fd, (w_addr *)out_addr) == E_SUCCESS) publish_addr(out_addr);
  else memset(out_addr, 0, X_ADDR_PORT_SIZE);
  return E_SUCCESS;
}

static uint32_t x_sock_addr(wasm_exec_env_t env, uint32_t fd, uint32_t ret, bool local) {
  uint8_t *out = app(env, ret, X_ADDR_PORT_SIZE);
  if (!out) return E_FAULT;
  memset(out, 0, X_ADDR_PORT_SIZE);
  uint32_t err = local ? W.sock_addr_local(env, fd, (w_addr *)out) : W.sock_addr_remote(env, fd, (w_addr *)out);
  if (err == E_SUCCESS) publish_addr(out);
  else memset(out, 0, X_ADDR_PORT_SIZE);
  return err;
}

static uint32_t x_sock_addr_local(wasm_exec_env_t env, uint32_t fd, uint32_t ret) {
  return x_sock_addr(env, fd, ret, true);
}

static uint32_t x_sock_addr_peer(wasm_exec_env_t env, uint32_t fd, uint32_t ret) {
  return x_sock_addr(env, fd, ret, false);
}

static uint32_t x_sock_recv_from(wasm_exec_env_t env, uint32_t fd, uint32_t iovs, uint32_t iovs_len,
                                 uint32_t flags, uint32_t ret_size, uint32_t ret_flags, uint32_t ret_addr) {
  void *vecs = app(env, iovs, (uint64_t)iovs_len * 8);
  uint32_t *out_size = app(env, ret_size, 4);
  uint16_t *out_flags = app(env, ret_flags, 2);
  uint8_t *out_addr = app(env, ret_addr, X_ADDR_PORT_SIZE);
  if ((!vecs && iovs_len) || !out_size || !out_flags || !out_addr) return E_FAULT;
  memset(out_addr, 0, X_ADDR_PORT_SIZE);
  uint32_t err = W.sock_recv_from(env, fd, vecs, iovs_len, (uint16_t)flags, (w_addr *)out_addr, out_size);
  if (err) return err;
  *out_flags = 0;
  publish_addr(out_addr);
  return E_SUCCESS;
}

static uint32_t x_sock_send_to(wasm_exec_env_t env, uint32_t fd, uint32_t iovs, uint32_t iovs_len,
                               uint32_t flags, uint32_t addr, uint32_t ret_size) {
  void *vecs = app(env, iovs, (uint64_t)iovs_len * 8);
  uint8_t *x = app(env, addr, X_ADDR_PORT_SIZE);
  uint32_t *out_size = app(env, ret_size, 4);
  if ((!vecs && iovs_len) || !x || !out_size) return E_FAULT;
  uint8_t saved[X_ADDR_PORT_SIZE];
  uint32_t err = stage_addr(x, saved);
  if (err == E_SUCCESS) err = W.sock_send_to(env, fd, vecs, iovs_len, (uint16_t)flags, (w_addr *)x, out_size);
  restore_addr(x, saved);
  return err;
}

static uint32_t x_sock_set_opt_flag(wasm_exec_env_t env, uint32_t fd, uint32_t opt, uint32_t flag) {
  bool on = flag != 0;
  switch (opt) {
  case X_OPT_REUSE_ADDR: return W.set_reuse_addr(env, fd, on);
  case X_OPT_REUSE_PORT: return W.set_reuse_port(env, fd, on);
  case X_OPT_NO_DELAY: return W.set_tcp_no_delay(env, fd, on);
  case X_OPT_KEEP_ALIVE: return W.set_keep_alive(env, fd, on);
  case X_OPT_BROADCAST: return W.set_broadcast(env, fd, on);
  case X_OPT_ONLY_V6: return W.set_ipv6_only(env, fd, on);
  default: return E_NOPROTOOPT;
  }
}

static uint32_t x_sock_get_opt_flag(wasm_exec_env_t env, uint32_t fd, uint32_t opt, uint32_t ret) {
  bool *out = app(env, ret, sizeof(bool));
  if (!out) return E_FAULT;
  switch (opt) {
  case X_OPT_REUSE_ADDR: return W.get_reuse_addr(env, fd, out);
  case X_OPT_REUSE_PORT: return W.get_reuse_port(env, fd, out);
  case X_OPT_NO_DELAY: return W.get_tcp_no_delay(env, fd, out);
  case X_OPT_KEEP_ALIVE: return W.get_keep_alive(env, fd, out);
  case X_OPT_BROADCAST: return W.get_broadcast(env, fd, out);
  case X_OPT_ONLY_V6: return W.get_ipv6_only(env, fd, out);
  default: return E_NOPROTOOPT;
  }
}

static uint32_t x_sock_set_opt_size(wasm_exec_env_t env, uint32_t fd, uint32_t opt, uint64_t size) {
  switch (opt) {
  case X_OPT_RECV_BUF_SIZE: return W.set_recv_buf_size(env, fd, (size_t)size);
  case X_OPT_SEND_BUF_SIZE: return W.set_send_buf_size(env, fd, (size_t)size);
  case X_OPT_TTL: return size > 255 ? E_INVAL : W.set_ip_ttl(env, fd, (uint8_t)size);
  default: return E_NOPROTOOPT;
  }
}

// The result is a __wasi_filesize_t (8 bytes), WAMR's a size_t: the same
// size on this 64-bit host.
_Static_assert(sizeof(size_t) == 8, "size_t is 64-bit");

static uint32_t x_sock_get_opt_size(wasm_exec_env_t env, uint32_t fd, uint32_t opt, uint32_t ret) {
  size_t *out = app(env, ret, 8);
  if (!out) return E_FAULT;
  switch (opt) {
  case X_OPT_RECV_BUF_SIZE: return W.get_recv_buf_size(env, fd, out);
  case X_OPT_SEND_BUF_SIZE: return W.get_send_buf_size(env, fd, out);
  default: return E_NOPROTOOPT;
  }
}

// WASIX times are nanoseconds; WAMR's socket timeouts microseconds, its
// linger seconds. A missing value (tag 0) turns the option off.
static uint32_t x_sock_set_opt_time(wasm_exec_env_t env, uint32_t fd, uint32_t opt, uint32_t timeout) {
  const uint8_t *t = app(env, timeout, X_OPTION_TS_SIZE);
  if (!t) return E_FAULT;
  bool some = t[0] != 0;
  uint64_t ns = some ? get_u64(t + 8) : 0;
  switch (opt) {
  case X_OPT_RECV_TIMEOUT: return W.set_recv_timeout(env, fd, ns / 1000);
  case X_OPT_SEND_TIMEOUT: return W.set_send_timeout(env, fd, ns / 1000);
  case X_OPT_LINGER: return W.set_linger(env, fd, some, (int)(ns / 1000000000ull));
  default: return E_NOPROTOOPT;
  }
}

// The option (16 bytes: tag, then the u64 at 8) is WAMR's scratch first.
static uint32_t x_sock_get_opt_time(wasm_exec_env_t env, uint32_t fd, uint32_t opt, uint32_t ret) {
  uint8_t *out = app(env, ret, X_OPTION_TS_SIZE);
  if (!out) return E_FAULT;
  memset(out, 0, X_OPTION_TS_SIZE);
  uint32_t err;
  switch (opt) {
  case X_OPT_RECV_TIMEOUT:
  case X_OPT_SEND_TIMEOUT: {
    uint64_t *us = (uint64_t *)(out + 8);
    err = opt == X_OPT_RECV_TIMEOUT ? W.get_recv_timeout(env, fd, us) : W.get_send_timeout(env, fd, us);
    if (err == E_SUCCESS && *us) { uint64_t ns = *us * 1000; out[0] = 1; put_u64(out + 8, ns); }
    else memset(out, 0, X_OPTION_TS_SIZE);
    return err;
  }
  case X_OPT_LINGER: {
    bool *on = (bool *)out;
    int *seconds = (int *)(out + 4);
    err = W.get_linger(env, fd, on, seconds);
    bool enabled = err == E_SUCCESS && *on;
    uint64_t ns = enabled ? (uint64_t)*seconds * 1000000000ull : 0;
    memset(out, 0, X_OPTION_TS_SIZE);
    if (enabled) { out[0] = 1; put_u64(out + 8, ns); }
    return err;
  }
  default: return E_NOPROTOOPT;
  }
}

static uint32_t x_sock_status(wasm_exec_env_t env, uint32_t fd, uint32_t ret) {
  (void)fd;
  uint8_t *out = app(env, ret, 1);
  if (!out) return E_FAULT;
  *out = X_SOCK_STATUS_OPENED;
  return E_SUCCESS;
}

// resolve(host, port, addrs, naddrs) -> count: every distinct address of the
// name, as __wasi_addr_ip_t. The program's addrs buffer is WAMR's scratch:
// the hints, the count and as many WAMR results as fit, read out before the
// WASIX entries are written over them.
static uint32_t x_resolve(wasm_exec_env_t env, uint32_t host, uint32_t host_len, uint32_t port,
                          uint32_t addrs, uint32_t naddrs, uint32_t ret) {
  const char *h = app(env, host, host_len);
  uint8_t *out = app(env, addrs, (uint64_t)naddrs * X_ADDR_IP_SIZE);
  uint32_t *count = app(env, ret, 4);
  if (!h || (!out && naddrs) || !count) return E_FAULT;
  if (host_len >= 256) return E_NAMETOOLONG;
  *count = 0;
  uint64_t bytes = (uint64_t)naddrs * X_ADDR_IP_SIZE;
  const uint64_t header = 16;  // hints (12), then the count (4)
  if (bytes < header + sizeof(w_addr_info)) return naddrs ? E_NOMEM : E_SUCCESS;
  uint32_t room = (uint32_t)((bytes - header) / sizeof(w_addr_info));
  char name[256];
  memcpy(name, h, host_len);
  name[host_len] = 0;
  char service[8];
  snprintf(service, sizeof service, "%u", port & 0xFFFF);
  w_hints *hints = (w_hints *)out;
  uint32_t *found = (uint32_t *)(out + 12);
  w_addr_info *info = (w_addr_info *)(out + header);
  *hints = (w_hints){W_SOCKET_ANY, W_INET_UNSPEC, 0};
  *found = 0;
  uint32_t err = W.sock_addr_resolve(env, name, service, hints, info, room, found);
  if (err) return err;
  uint32_t total = *found < room ? *found : room;
  if (total > 64) total = 64;
  w_addr_info results[64];
  memcpy(results, info, total * sizeof(w_addr_info));
  memset(out, 0, bytes);
  uint32_t n = 0;
  for (uint32_t i = 0; i < total && n < naddrs; i++) {
    uint8_t entry[X_ADDR_IP_SIZE] = {0};
    if (results[i].addr.kind == W_IPV4) {
      entry[0] = X_AF_INET4;
      entry[2] = results[i].addr.addr.ip4.addr.n0;
      entry[3] = results[i].addr.addr.ip4.addr.n1;
      entry[4] = results[i].addr.addr.ip4.addr.n2;
      entry[5] = results[i].addr.addr.ip4.addr.n3;
    } else {
      entry[0] = X_AF_INET6;
      for (int k = 0; k < 8; k++) put_u16(entry + 2 + 2 * k, results[i].addr.addr.ip6.addr.s[k]);
    }
    bool duplicate = false;
    for (uint32_t j = 0; j < n && !duplicate; j++)
      duplicate = memcmp(out + j * X_ADDR_IP_SIZE, entry, X_ADDR_IP_SIZE) == 0;
    if (!duplicate) memcpy(out + (n++) * X_ADDR_IP_SIZE, entry, X_ADDR_IP_SIZE);
  }
  *count = n;
  return E_SUCCESS;
}

// --- Futexes ----------------------------------------------------------------

#define FUTEX_BUCKETS 64
static struct futex_bucket {
  pthread_mutex_t lock;
  pthread_cond_t cond;
} g_futex[FUTEX_BUCKETS];
static pthread_once_t g_futex_once = PTHREAD_ONCE_INIT;

static void futex_init(void) {
  for (int i = 0; i < FUTEX_BUCKETS; i++) {
    pthread_mutex_init(&g_futex[i].lock, NULL);
    pthread_cond_init(&g_futex[i].cond, NULL);
  }
}

static struct futex_bucket *bucket(const void *p) {
  uintptr_t a = (uintptr_t)p;
  return &g_futex[(a >> 2) % FUTEX_BUCKETS];
}

// Waits while *futex == expected, until woken or the timeout (ns) passes.
// Wakes broadcast to the bucket; a waiter that wakes for another address
// re-checks its value and waits again, as futex users expect.
static uint32_t x_futex_wait(wasm_exec_env_t env, uint32_t futex, uint32_t expected, uint32_t timeout,
                             uint32_t ret) {
  volatile uint32_t *word = app(env, futex, 4);
  uint8_t *woken = app(env, ret, 1);
  const uint8_t *t = timeout ? app(env, timeout, X_OPTION_TS_SIZE) : NULL;
  if (!word || !woken || (timeout && !t)) return E_FAULT;
  pthread_once(&g_futex_once, futex_init);
  struct futex_bucket *b = bucket((const void *)word);
  struct timespec deadline;
  bool timed = t && t[0];
  if (timed) {
    uint64_t ns = get_u64(t + 8);
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)(ns / 1000000000ull);
    deadline.tv_nsec += (long)(ns % 1000000000ull);
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
  }
  pthread_mutex_lock(&b->lock);
  *woken = 0;
  uint32_t err = E_SUCCESS;
  if (__atomic_load_n(word, __ATOMIC_SEQ_CST) == expected) {
    int rc = timed ? pthread_cond_timedwait(&b->cond, &b->lock, &deadline) : pthread_cond_wait(&b->cond, &b->lock);
    if (rc == ETIMEDOUT) err = E_TIMEDOUT;
    else *woken = 1;
  }
  pthread_mutex_unlock(&b->lock);
  return err;
}

static uint32_t x_futex_wake_any(wasm_exec_env_t env, uint32_t futex, uint32_t ret) {
  void *word = app(env, futex, 4);
  uint8_t *woken = app(env, ret, 1);
  if (!word || !woken) return E_FAULT;
  pthread_once(&g_futex_once, futex_init);
  struct futex_bucket *b = bucket(word);
  pthread_mutex_lock(&b->lock);
  pthread_cond_broadcast(&b->cond);
  pthread_mutex_unlock(&b->lock);
  *woken = 1;
  return E_SUCCESS;
}

// --- Threads and process ------------------------------------------------------

// The thread that started the module, outside wasi-threads' id range.
#define MAIN_THREAD_ID 0x1FFFFFFF

static uint32_t x_thread_id(wasm_exec_env_t env, uint32_t ret) {
  uint32_t *out = app(env, ret, 4);
  if (!out) return E_FAULT;
  int32_t id = lst_wasi_threads_current_id(env);
  *out = id < 0 ? MAIN_THREAD_ID : (uint32_t)id;
  return E_SUCCESS;
}

static void x_thread_exit(wasm_exec_env_t env, uint32_t code) {
  if (!lst_wasi_threads_exit_current(env))
    W.proc_exit(env, code);  // the main thread: the program ends
}

static void x_proc_exit2(wasm_exec_env_t env, uint32_t code) { W.proc_exit(env, code); }

static uint32_t x_thread_sleep(wasm_exec_env_t env, uint64_t ns) {
  (void)env;
  struct timespec t = {(time_t)(ns / 1000000000ull), (long)(ns % 1000000000ull)};
  while (nanosleep(&t, &t) != 0 && errno == EINTR) {}
  return E_SUCCESS;
}

static uint32_t x_thread_parallelism(wasm_exec_env_t env, uint32_t ret) {
  uint32_t *out = app(env, ret, 4);
  if (!out) return E_FAULT;
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  *out = n > 0 ? (uint32_t)n : 1;
  return E_SUCCESS;
}

static uint32_t x_proc_id(wasm_exec_env_t env, uint32_t ret) {
  uint32_t *out = app(env, ret, 4);
  if (!out) return E_FAULT;
  *out = 1;
  return E_SUCCESS;
}

static uint32_t x_proc_parent(wasm_exec_env_t env, uint32_t pid, uint32_t ret) {
  (void)pid;
  uint32_t *out = app(env, ret, 4);
  if (!out) return E_FAULT;
  *out = 0;
  return E_SUCCESS;
}

// --- Signals: the program's own ---------------------------------------------

static void x_callback_signal(wasm_exec_env_t env, uint32_t name, uint32_t len) {
  const char *s = app(env, name, len);
  program_state *st = state_of(wasm_runtime_get_module_inst(env));
  if (!s || !st || len >= sizeof st->signal_callback) return;
  pthread_mutex_lock(&st->lock);
  memcpy(st->signal_callback, s, len);
  st->signal_callback[len] = 0;
  pthread_mutex_unlock(&st->lock);
}

// Delivers a signal by calling the program's handler entry point on this
// thread (raise and pthread_kill of the calling thread). Signals for other
// threads are delivered here too: WAMR cannot interrupt a running thread.
static uint32_t x_thread_signal(wasm_exec_env_t env, uint32_t tid, uint32_t sig) {
  (void)tid;
  wasm_module_inst_t inst = wasm_runtime_get_module_inst(env);
  program_state *st = state_of(inst);
  if (!st) return E_NOMEM;
  char name[sizeof st->signal_callback];
  pthread_mutex_lock(&st->lock);
  memcpy(name, st->signal_callback, sizeof name);
  pthread_mutex_unlock(&st->lock);
  if (!name[0]) return E_SUCCESS;
  wasm_function_inst_t f = wasm_runtime_lookup_function(inst, name);
  if (!f) return E_SUCCESS;
  uint32_t argv[1] = {sig};
  wasm_runtime_call_wasm(env, f, 1, argv);
  return E_SUCCESS;
}

static uint32_t x_proc_signals_sizes_get(wasm_exec_env_t env, uint32_t ret) {
  uint32_t *out = app(env, ret, 4);
  if (!out) return E_FAULT;
  *out = 0;
  return E_SUCCESS;
}

static uint32_t x_proc_signals_get(wasm_exec_env_t env, uint32_t buf) {
  (void)env;
  (void)buf;
  return E_SUCCESS;
}

// --- Files and the working directory -----------------------------------------

static uint32_t x_getcwd(wasm_exec_env_t env, uint32_t buf, uint32_t len_ptr) {
  uint32_t *len = app(env, len_ptr, 4);
  if (!len) return E_FAULT;
  program_state *st = state_of(wasm_runtime_get_module_inst(env));
  if (!st) return E_NOMEM;
  pthread_mutex_lock(&st->lock);
  uint32_t need = (uint32_t)strlen(st->cwd);
  uint32_t err = E_SUCCESS;
  if (*len < need + 1) {
    err = E_RANGE;
  } else {
    char *out = app(env, buf, need + 1);
    if (!out) err = E_FAULT;
    else memcpy(out, st->cwd, need + 1);
  }
  *len = need;
  pthread_mutex_unlock(&st->lock);
  return err;
}

static uint32_t x_chdir(wasm_exec_env_t env, uint32_t path, uint32_t path_len) {
  const char *p = app(env, path, path_len);
  program_state *st = state_of(wasm_runtime_get_module_inst(env));
  if (!p) return E_FAULT;
  if (!st) return E_NOMEM;
  pthread_mutex_lock(&st->lock);
  char next[1024];
  int n;
  if (path_len && p[0] == '/')
    n = snprintf(next, sizeof next, "%.*s", (int)path_len, p);
  else
    n = snprintf(next, sizeof next, "%s%s%.*s", st->cwd, strcmp(st->cwd, "/") == 0 ? "" : "/", (int)path_len, p);
  uint32_t err = E_SUCCESS;
  if (n < 0 || n >= (int)sizeof next) err = E_NAMETOOLONG;
  else strcpy(st->cwd, next);
  pthread_mutex_unlock(&st->lock);
  return err;
}

// The arguments after the seventh arrive on the stack, where WAMR's native
// call gives each an 8-byte slot; Apple's arm64 convention packs 32-bit stack
// arguments into 4 bytes. Declared 64-bit, they are read from the right slots.
static uint32_t x_path_open2(wasm_exec_env_t env, uint32_t dirfd, uint32_t dirflags, uint32_t path,
                             uint32_t path_len, uint32_t oflags, uint64_t base, uint64_t inheriting,
                             uint64_t fdflags, uint64_t fdflagsext, uint64_t ret) {
  (void)fdflagsext;  // close-on-exec: nothing executes another program here
  const char *p = app(env, path, path_len);
  uint32_t *out = app(env, (uint32_t)ret, 4);
  if (!p || !out) return E_FAULT;
  return W.path_open(env, dirfd, dirflags, p, path_len, (uint16_t)oflags, base, inheriting, (uint16_t)fdflags, out);
}

static uint32_t x_fd_fdflags_get(wasm_exec_env_t env, uint32_t fd, uint32_t ret) {
  (void)fd;
  uint16_t *out = app(env, ret, 2);
  if (!out) return E_FAULT;
  *out = 0;
  return E_SUCCESS;
}

static uint32_t x_fd_fdflags_set(wasm_exec_env_t env, uint32_t fd, uint32_t flags) {
  (void)env;
  (void)fd;
  (void)flags;
  return E_SUCCESS;
}

// --- Terminal -----------------------------------------------------------------

static uint32_t x_tty_get(wasm_exec_env_t env, uint32_t state) {
  uint8_t *t = app(env, state, X_TTY_SIZE);
  if (!t) return E_FAULT;
  memset(t, 0, X_TTY_SIZE);
  put_u32(t + 0, 80);   // cols
  put_u32(t + 4, 24);   // rows
  t[16] = 1;            // stdin_tty
  t[17] = 1;            // stdout_tty
  t[18] = 1;            // stderr_tty
  t[19] = 1;            // echo (the terminal echoes typed lines)
  t[20] = 1;            // line_buffered
  t[21] = 1;            // line_feeds
  return E_SUCCESS;
}

static uint32_t x_tty_set(wasm_exec_env_t env, uint32_t state) {
  return app(env, state, X_TTY_SIZE) ? E_SUCCESS : E_FAULT;
}

// --- Everything else: ENOSYS --------------------------------------------------

// A raw native (no signature check) for any call that returns an errno.
static void x_enosys(wasm_exec_env_t env, uint64_t *args) {
  (void)env;
  *(uint32_t *)args = E_NOSYS;
}

static const char *const g_enosys[] = {
    "call_dynamic", "clock_time_set", "closure_allocate", "closure_free", "closure_prepare",
    "context_create", "context_destroy", "context_switch", "dl_invalid_handle", "dlopen", "dlsym",
    "epoll_create", "epoll_ctl", "epoll_wait", "fd_dup", "fd_dup2", "fd_event", "fd_pipe",
    "port_addr_add", "port_addr_clear", "port_addr_list", "port_addr_remove", "port_bridge",
    "port_dhcp_acquire", "port_gateway_set", "port_mac", "port_route_add", "port_route_clear",
    "port_route_list", "port_route_remove", "port_unbridge", "proc_exec", "proc_exec2", "proc_exec3",
    "proc_exec4", "proc_fork", "proc_fork_env", "proc_join", "proc_raise_interval", "proc_signal",
    "proc_snapshot", "proc_spawn", "proc_spawn2", "proc_spawn3", "reflect_signature",
    "sock_join_multicast_v4", "sock_join_multicast_v6", "sock_leave_multicast_v4",
    "sock_leave_multicast_v6", "sock_pair", "sock_send_file", "stack_checkpoint", "stack_restore",
    "thread_join", "thread_spawn_v2",
};

#define N(name, fn, sig) {name, (void *)(fn), sig, NULL}
static NativeSymbol g_natives[] = {
    N("sock_open", x_sock_open, "(iiii)i"),
    N("sock_bind", x_sock_bind, "(ii)i"),
    N("sock_connect", x_sock_connect, "(ii)i"),
    N("sock_listen", x_sock_listen, "(ii)i"),
    N("sock_accept_v2", x_sock_accept_v2, "(iiii)i"),
    N("sock_addr_local", x_sock_addr_local, "(ii)i"),
    N("sock_addr_peer", x_sock_addr_peer, "(ii)i"),
    N("sock_recv_from", x_sock_recv_from, "(iiiiiii)i"),
    N("sock_send_to", x_sock_send_to, "(iiiiii)i"),
    N("sock_set_opt_flag", x_sock_set_opt_flag, "(iii)i"),
    N("sock_get_opt_flag", x_sock_get_opt_flag, "(iii)i"),
    N("sock_set_opt_size", x_sock_set_opt_size, "(iiI)i"),
    N("sock_get_opt_size", x_sock_get_opt_size, "(iii)i"),
    N("sock_set_opt_time", x_sock_set_opt_time, "(iii)i"),
    N("sock_get_opt_time", x_sock_get_opt_time, "(iii)i"),
    N("sock_status", x_sock_status, "(ii)i"),
    N("resolve", x_resolve, "(iiiiii)i"),
    N("futex_wait", x_futex_wait, "(iiii)i"),
    N("futex_wake", x_futex_wake_any, "(ii)i"),
    N("futex_wake_all", x_futex_wake_any, "(ii)i"),
    N("thread_id", x_thread_id, "(i)i"),
    N("thread_exit", x_thread_exit, "(i)"),
    N("thread_sleep", x_thread_sleep, "(I)i"),
    N("thread_parallelism", x_thread_parallelism, "(i)i"),
    N("thread_signal", x_thread_signal, "(ii)i"),
    N("callback_signal", x_callback_signal, "(ii)"),
    N("proc_exit2", x_proc_exit2, "(i)"),
    N("proc_id", x_proc_id, "(i)i"),
    N("proc_parent", x_proc_parent, "(ii)i"),
    N("proc_signals_get", x_proc_signals_get, "(i)i"),
    N("proc_signals_sizes_get", x_proc_signals_sizes_get, "(i)i"),
    N("getcwd", x_getcwd, "(ii)i"),
    N("chdir", x_chdir, "(ii)i"),
    N("path_open2", x_path_open2, "(iiiiiIIiii)i"),
    N("fd_fdflags_get", x_fd_fdflags_get, "(ii)i"),
    N("fd_fdflags_set", x_fd_fdflags_set, "(ii)i"),
    N("tty_get", x_tty_get, "(i)i"),
    N("tty_set", x_tty_set, "(i)i"),
};
#undef N

static NativeSymbol g_stubs[sizeof g_enosys / sizeof g_enosys[0]];

bool lst_wasix_register(void) {
  NativeSymbol *apis = NULL;
  uint32_t count = get_libc_wasi_export_apis(&apis);
#define GET(field, name) W.field = find_native(apis, count, name)
  GET(sock_open, "sock_open");
  GET(sock_bind, "sock_bind");
  GET(sock_connect, "sock_connect");
  GET(sock_addr_local, "sock_addr_local");
  GET(sock_addr_remote, "sock_addr_remote");
  GET(sock_listen, "sock_listen");
  GET(sock_accept, "sock_accept");
  GET(sock_addr_resolve, "sock_addr_resolve");
  GET(sock_recv_from, "sock_recv_from");
  GET(sock_send_to, "sock_send_to");
  GET(set_reuse_addr, "sock_set_reuse_addr");
  GET(set_reuse_port, "sock_set_reuse_port");
  GET(set_tcp_no_delay, "sock_set_tcp_no_delay");
  GET(set_keep_alive, "sock_set_keep_alive");
  GET(set_broadcast, "sock_set_broadcast");
  GET(set_ipv6_only, "sock_set_ipv6_only");
  GET(get_reuse_addr, "sock_get_reuse_addr");
  GET(get_reuse_port, "sock_get_reuse_port");
  GET(get_tcp_no_delay, "sock_get_tcp_no_delay");
  GET(get_keep_alive, "sock_get_keep_alive");
  GET(get_broadcast, "sock_get_broadcast");
  GET(get_ipv6_only, "sock_get_ipv6_only");
  GET(set_recv_buf_size, "sock_set_recv_buf_size");
  GET(set_send_buf_size, "sock_set_send_buf_size");
  GET(get_recv_buf_size, "sock_get_recv_buf_size");
  GET(get_send_buf_size, "sock_get_send_buf_size");
  GET(set_recv_timeout, "sock_set_recv_timeout");
  GET(set_send_timeout, "sock_set_send_timeout");
  GET(get_recv_timeout, "sock_get_recv_timeout");
  GET(get_send_timeout, "sock_get_send_timeout");
  GET(set_linger, "sock_set_linger");
  GET(get_linger, "sock_get_linger");
  GET(set_ip_ttl, "sock_set_ip_ttl");
  GET(path_open, "path_open");
  GET(proc_exit, "proc_exit");
#undef GET
  void **fields = (void **)&W;
  for (size_t i = 0; i < sizeof W / sizeof(void *); i++)
    if (!fields[i]) return false;
  for (size_t i = 0; i < sizeof g_enosys / sizeof g_enosys[0]; i++)
    g_stubs[i] = (NativeSymbol){g_enosys[i], (void *)x_enosys, "", NULL};
  return wasm_runtime_register_natives("wasix_32v1", g_natives, sizeof g_natives / sizeof g_natives[0]) &&
         wasm_runtime_register_natives_raw("wasix_32v1", g_stubs, sizeof g_stubs / sizeof g_stubs[0]);
}

const char *lst_wasix_coverage(void) {
  static char text[4096];
  if (text[0]) return text;
  size_t used = 0;
  for (size_t i = 0; i < sizeof g_natives / sizeof g_natives[0]; i++)
    used += (size_t)snprintf(text + used, sizeof text - used, "%s:implemented\n", g_natives[i].symbol);
  for (size_t i = 0; i < sizeof g_enosys / sizeof g_enosys[0]; i++)
    used += (size_t)snprintf(text + used, sizeof text - used, "%s:enosys\n", g_enosys[i]);
  return text;
}

#else  // !LST_HAVE_WAMR

bool lst_wasix_register(void) { return false; }
const char *lst_wasix_coverage(void) { return ""; }

#endif
