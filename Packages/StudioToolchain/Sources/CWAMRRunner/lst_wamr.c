// In-process WASI runner on WAMR's fast interpreter. See include/lst_wamr.h.

#include "lst_wamr.h"

// Written by build-wamr-ios.sh (1) or make-stub-xcframeworks.sh (0).
#include <lemonseed/wamr_config.h>

#if LST_HAVE_WAMR

#include <wamr/wasm_export.h>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct lst_wamr_session {
  pthread_mutex_t lock;
  wasm_module_inst_t running; // guarded by lock
  bool terminate_requested;   // guarded by lock
};

typedef struct reader {
  int fd;      // read end of the pipe
  int guest_fd; // 1 or 2, reported to the callback
  const lst_wamr_options *options;
  pthread_t thread;
  bool started;
} reader;

static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;
static bool g_init_ok;

/// Threads one program may start (wasi-threads, WASIX thread_spawn).
#define LST_MAX_THREADS 64

static void runtime_init(void) {
  RuntimeInitArgs args;
  memset(&args, 0, sizeof args);
  args.mem_alloc_type = Alloc_With_System_Allocator;
  args.max_thread_num = LST_MAX_THREADS;
  g_init_ok = wasm_runtime_full_init(&args);
}

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static void *reader_main(void *arg) {
  reader *r = arg;
  char buffer[4096];
  for (;;) {
    ssize_t n = read(r->fd, buffer, sizeof buffer);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      break;
    if (r->options->output)
      r->options->output(r->options->user, r->guest_fd, buffer, (size_t)n);
  }
  return NULL;
}

static bool reader_start(reader *r, int write_fds[1], int guest_fd,
                         const lst_wamr_options *options) {
  int fds[2];
  if (pipe(fds) != 0)
    return false;
  r->fd = fds[0];
  r->guest_fd = guest_fd;
  r->options = options;
  write_fds[0] = fds[1];
  r->started = pthread_create(&r->thread, NULL, reader_main, r) == 0;
  if (!r->started) {
    close(fds[0]);
    close(fds[1]);
  }
  return r->started;
}

static void reader_finish(reader *r) {
  if (!r->started)
    return;
  pthread_join(r->thread, NULL);
  close(r->fd);
  r->started = false;
}

lst_wamr_session *lst_wamr_session_create(void) {
  lst_wamr_session *s = calloc(1, sizeof *s);
  if (s)
    pthread_mutex_init(&s->lock, NULL);
  return s;
}

void lst_wamr_session_destroy(lst_wamr_session *s) {
  if (!s)
    return;
  pthread_mutex_destroy(&s->lock);
  free(s);
}

void lst_wamr_session_terminate(lst_wamr_session *s) {
  pthread_mutex_lock(&s->lock);
  s->terminate_requested = true;
  if (s->running)
    wasm_runtime_terminate(s->running);
  pthread_mutex_unlock(&s->lock);
}

const char *lst_wamr_version(void) {
  static char version[64];
  uint32_t major = 0, minor = 0, patch = 0;
  wasm_runtime_get_version(&major, &minor, &patch);
  snprintf(version, sizeof version, "WAMR %u.%u.%u fast interpreter", major,
           minor, patch);
  return version;
}

int lst_wamr_session_run(lst_wamr_session *s, const lst_wamr_options *o,
                         lst_wamr_result *result) {
  memset(result, 0, sizeof *result);
  result->exit_code = -1;

  pthread_once(&g_init_once, runtime_init);
  if (!g_init_ok) {
    snprintf(result->error, sizeof result->error, "WAMR failed to initialize");
    return -1;
  }
  bool thread_env = wasm_runtime_init_thread_env();

  uint8_t *bytes = malloc(o->wasm_length ? o->wasm_length : 1);
  wasm_module_t module = NULL;
  wasm_module_inst_t inst = NULL;
  reader out = {0}, err = {0};
  int out_w = -1, err_w = -1, null_in = -1;
  double t0 = now_ms();

  if (!bytes) {
    snprintf(result->error, sizeof result->error, "out of memory");
    goto done;
  }
  memcpy(bytes, o->wasm, o->wasm_length); // WAMR may patch the buffer in place

  module = wasm_runtime_load(bytes, (uint32_t)o->wasm_length, result->error,
                             sizeof result->error);
  result->load_ms = now_ms() - t0;
  if (!module)
    goto done;

  if (!reader_start(&out, &out_w, 1, o) || !reader_start(&err, &err_w, 2, o)) {
    snprintf(result->error, sizeof result->error, "could not create pipes");
    goto done;
  }

  // WAMR takes -1 to mean the app's own stdin; a program without input gets
  // /dev/null (end of file) instead.
  int stdin_fd = o->stdin_fd;
  if (stdin_fd < 0) {
    null_in = open("/dev/null", O_RDONLY);
    stdin_fd = null_in;
  }

  const char *map_dirs[2];
  char map_buffer[1024 + 4];
  uint32_t map_count = 0;
  if (o->preopen_dir && *o->preopen_dir) {
    snprintf(map_buffer, sizeof map_buffer, ".::%s", o->preopen_dir);
    map_dirs[map_count++] = map_buffer;
  }
  wasm_runtime_set_wasi_args_ex(module, NULL, 0, map_dirs, map_count,
                                (const char **)o->env, (uint32_t)o->env_count,
                                (char **)o->argv, o->argc, stdin_fd, out_w, err_w);
  if (o->allow_network) {
    // WAMR checks every socket address and name lookup against these pools:
    // any IPv4 or IPv6 address, any name.
    static const char *any_address[] = {"0.0.0.0/0", "::/0"};
    static const char *any_name[] = {"*"};
    wasm_runtime_set_wasi_addr_pool(module, any_address, 2);
    wasm_runtime_set_wasi_ns_lookup_pool(module, any_name, 1);
  }

  double t1 = now_ms();
  inst = wasm_runtime_instantiate(module, o->stack_size ? o->stack_size : 256 * 1024,
                                  o->heap_size, result->error,
                                  sizeof result->error);
  result->instantiate_ms = now_ms() - t1;
  if (!inst)
    goto done;

  pthread_mutex_lock(&s->lock);
  s->running = inst;
  bool cancelled = s->terminate_requested;
  pthread_mutex_unlock(&s->lock);
  if (cancelled) {
    snprintf(result->error, sizeof result->error, "terminated");
    goto done;
  }

  double t2 = now_ms();
  bool ok = wasm_application_execute_main(inst, 0, NULL);
  result->run_ms = now_ms() - t2;

  const char *exception = wasm_runtime_get_exception(inst);
  if (ok || (exception && strstr(exception, "wasi proc exit"))) {
    result->exit_code = (int)wasm_runtime_get_wasi_exit_code(inst);
  } else {
    snprintf(result->error, sizeof result->error, "%s",
             exception ? exception : "the module trapped");
  }

  pthread_mutex_lock(&s->lock);
  s->running = NULL;
  pthread_mutex_unlock(&s->lock);

done:
  if (inst)
    wasm_runtime_deinstantiate(inst);
  if (module)
    wasm_runtime_unload(module);
  // Closing the write ends lets the readers drain and see end of file.
  if (out_w >= 0)
    close(out_w);
  if (err_w >= 0)
    close(err_w);
  if (null_in >= 0)
    close(null_in);
  reader_finish(&out);
  reader_finish(&err);
  free(bytes);
  if (thread_env)
    wasm_runtime_destroy_thread_env();
  return result->exit_code;
}

#else // !LST_HAVE_WAMR

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct lst_wamr_session { int unused; };

lst_wamr_session *lst_wamr_session_create(void) {
  return calloc(1, sizeof(lst_wamr_session));
}
void lst_wamr_session_destroy(lst_wamr_session *s) { free(s); }
void lst_wamr_session_terminate(lst_wamr_session *s) { (void)s; }
const char *lst_wamr_version(void) { return "WAMR not built"; }

int lst_wamr_session_run(lst_wamr_session *s, const lst_wamr_options *o,
                         lst_wamr_result *result) {
  (void)s; (void)o;
  memset(result, 0, sizeof *result);
  result->exit_code = -1;
  snprintf(result->error, sizeof result->error,
           "WAMR is not built into this app. Run "
           "Toolchain/scripts/build-wamr-ios.sh, then rebuild.");
  return -1;
}

#endif
