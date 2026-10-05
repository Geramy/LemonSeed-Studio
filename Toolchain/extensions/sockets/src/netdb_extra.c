// LemonSeed Studio: the parts of <netdb.h> WAMR's socket extension leaves out.

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>

int h_errno;

const char *gai_strerror(int ecode) {
  switch (ecode) {
  case 0: return "Success";
  case EAI_AGAIN: return "Temporary failure in name resolution";
  case EAI_BADFLAGS: return "Invalid flags";
  case EAI_FAIL: return "Non-recoverable failure in name resolution";
  case EAI_FAMILY: return "Address family not supported";
  case EAI_MEMORY: return "Out of memory";
  case EAI_NONAME: return "Name or service not known";
  case EAI_OVERFLOW: return "Argument buffer overflow";
  case EAI_SERVICE: return "Service not supported for socket type";
  case EAI_SOCKTYPE: return "Socket type not supported";
  case EAI_SYSTEM: return strerror(errno);
  default: return "Unknown error";
  }
}

// Numeric only: WASI has no reverse lookup.
int getnameinfo(const struct sockaddr *restrict sa, socklen_t salen, char *restrict host,
                socklen_t hostlen, char *restrict serv, socklen_t servlen, int flags) {
  if (flags & NI_NAMEREQD) return EAI_NONAME;
  const void *addr;
  unsigned port;
  if (sa->sa_family == AF_INET && salen >= sizeof(struct sockaddr_in)) {
    const struct sockaddr_in *in = (const struct sockaddr_in *)sa;
    addr = &in->sin_addr;
    port = ntohs(in->sin_port);
  } else if (sa->sa_family == AF_INET6 && salen >= sizeof(struct sockaddr_in6)) {
    const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)sa;
    addr = &in6->sin6_addr;
    port = ntohs(in6->sin6_port);
  } else {
    return EAI_FAMILY;
  }
  if (host && hostlen && !inet_ntop(sa->sa_family, addr, host, hostlen)) return EAI_OVERFLOW;
  if (serv && servlen && snprintf(serv, servlen, "%u", port) >= (int)servlen) return EAI_OVERFLOW;
  return 0;
}

struct hostent *gethostbyname(const char *name) {
  static struct hostent entry;
  static struct in_addr address;
  static char *addresses[2];
  static char *aliases[1];
  static char canonical[256];
  struct addrinfo hints = {0}, *result = NULL;
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  int rc = getaddrinfo(name, NULL, &hints, &result);
  if (rc != 0 || !result) {
    h_errno = rc == EAI_AGAIN ? TRY_AGAIN : HOST_NOT_FOUND;
    return NULL;
  }
  address = ((struct sockaddr_in *)result->ai_addr)->sin_addr;
  freeaddrinfo(result);
  snprintf(canonical, sizeof canonical, "%s", name);
  addresses[0] = (char *)&address;
  addresses[1] = NULL;
  aliases[0] = NULL;
  entry.h_name = canonical;
  entry.h_aliases = aliases;
  entry.h_addrtype = AF_INET;
  entry.h_length = sizeof address;
  entry.h_addr_list = addresses;
  return &entry;
}
