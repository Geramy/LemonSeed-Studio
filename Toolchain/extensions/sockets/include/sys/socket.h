/* LemonSeed Studio: BSD sockets for wasm32-wasip1 programs.
 *
 * wasi-libc's <sys/socket.h> declares only what WASI preview 1 has (accept,
 * recv, send, shutdown). WAMR, which runs programs that use sockets, also
 * implements socket, bind, listen, connect, getaddrinfo and the socket
 * options; wasi_socket_ext.h declares them and libwasi_socket_ext.a (linked
 * by default) implements them over WAMR's calls. This header sits ahead of
 * the sysroot, so standard socket code compiles unchanged. */
#include_next <sys/socket.h>
#include <wasi_socket_ext.h>
