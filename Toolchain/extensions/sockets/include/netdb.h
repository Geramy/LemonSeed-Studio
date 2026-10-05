/* LemonSeed Studio: <netdb.h> for wasm32-wasip1 programs (wasi-libc has
 * none). getaddrinfo, freeaddrinfo and struct addrinfo come from WAMR's
 * socket extension; the rest is in libwasi_socket_ext.a (netdb_extra.c). */
#ifndef LST_NETDB_H
#define LST_NETDB_H

#include <sys/socket.h>
#include <netinet/in.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AI_PASSIVE     0x01
#define AI_CANONNAME   0x02
#define AI_NUMERICHOST 0x04
#define AI_V4MAPPED    0x08
#define AI_ALL         0x10
#define AI_ADDRCONFIG  0x20
#define AI_NUMERICSERV 0x400

#define NI_NUMERICHOST 0x01
#define NI_NUMERICSERV 0x02
#define NI_NOFQDN      0x04
#define NI_NAMEREQD    0x08
#define NI_DGRAM       0x10
#define NI_MAXHOST 255
#define NI_MAXSERV 32

const char *gai_strerror(int ecode);
int getnameinfo(const struct sockaddr *__restrict sa, socklen_t salen, char *__restrict host,
                socklen_t hostlen, char *__restrict serv, socklen_t servlen, int flags);

struct hostent {
  char *h_name;
  char **h_aliases;
  int h_addrtype;
  int h_length;
  char **h_addr_list;
};
#define h_addr h_addr_list[0]

/* IPv4 only, one address, not thread-safe (as in POSIX). */
struct hostent *gethostbyname(const char *name);

extern int h_errno;
#define HOST_NOT_FOUND 1
#define TRY_AGAIN      2
#define NO_RECOVERY    3
#define NO_DATA        4

#ifdef __cplusplus
}
#endif
#endif
