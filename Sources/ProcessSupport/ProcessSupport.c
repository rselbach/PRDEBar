#include "ProcessSupport.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <unistd.h>

int prde_spawn(const char *path, char *const argv[], char *const envp[], pid_t *pid) {
  posix_spawnattr_t attributes;
  posix_spawn_file_actions_t actions;
  int error = posix_spawnattr_init(&attributes);
  if (error) return error;
  error = posix_spawn_file_actions_init(&actions);
  if (error) {
    posix_spawnattr_destroy(&attributes);
    return error;
  }

  // A new group owns hcloud and its inherited doormat/ssh descendants.
  error = posix_spawnattr_setflags(&attributes,
                                  POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
  if (!error) error = posix_spawnattr_setpgroup(&attributes, 0);
  if (!error) error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  if (!error) error = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
  if (!error) error = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
  if (!error) error = posix_spawn(pid, path, &actions, &attributes, argv, envp);
  int action_error = posix_spawn_file_actions_destroy(&actions);
  int attr_error = posix_spawnattr_destroy(&attributes);
  if (error) return error;
  if (action_error) return action_error;
  return attr_error;
}

static int processes_listen(uint32_t type, uint32_t typeinfo, uint16_t port);

int prde_port_available(uint16_t port) {
  // macOS permits wildcard and loopback binds to coexist with SO_REUSEADDR.
  if (processes_listen(PROC_ALL_PIDS, 0, port)) return EADDRINUSE;
  int families[] = {AF_INET, AF_INET6};
  for (int i = 0; i < 2; i++) {
    int fd = socket(families[i], SOCK_STREAM, 0);
    if (fd == -1) return errno;
    int reuse = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) == -1) {
      int error = errno;
      close(fd);
      return error;
    }
    int result;
    if (families[i] == AF_INET) {
      struct sockaddr_in address = {.sin_len = sizeof(address),
                                    .sin_family = AF_INET,
                                    .sin_port = htons(port),
                                    .sin_addr.s_addr = INADDR_ANY};
      result = bind(fd, (struct sockaddr *)&address, sizeof(address));
    } else {
      int yes = 1;
      result = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, sizeof(yes));
      if (result == 0) {
        struct sockaddr_in6 address = {.sin6_len = sizeof(address),
                                      .sin6_family = AF_INET6,
                                      .sin6_port = htons(port),
                                      .sin6_addr = IN6ADDR_ANY_INIT};
        result = bind(fd, (struct sockaddr *)&address, sizeof(address));
      }
    }
    if (result == 0) result = listen(fd, 1);
    int error = result == -1 ? errno : 0;
    if (close(fd) == -1 && !error) error = errno;
    if (error) return error;
  }
  return 0;
}

static int processes_listen(uint32_t type, uint32_t typeinfo, uint16_t port) {
  int bytes = proc_listpids(type, typeinfo, NULL, 0);
  if (bytes <= 0) return 0;
  int capacity = bytes + 32 * (int)sizeof(pid_t);
  pid_t *pids = malloc(capacity);
  if (!pids) return 0;
  bytes = proc_listpids(type, typeinfo, pids, capacity);
  int found = 0;
  for (int i = 0; i < bytes / (int)sizeof(pid_t) && !found; i++) {
    int size = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, NULL, 0);
    if (size <= 0) continue;
    int fd_capacity = size + 32 * (int)sizeof(struct proc_fdinfo);
    struct proc_fdinfo *fds = malloc(fd_capacity);
    if (!fds) continue;
    size = proc_pidinfo(pids[i], PROC_PIDLISTFDS, 0, fds, fd_capacity);
    for (int j = 0; j < size / (int)sizeof(struct proc_fdinfo); j++) {
      if (fds[j].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
      struct socket_fdinfo info;
      int count = proc_pidfdinfo(pids[i], fds[j].proc_fd, PROC_PIDFDSOCKETINFO,
                                &info, sizeof(info));
      if (count != sizeof(info) || info.psi.soi_kind != SOCKINFO_TCP) continue;
      struct tcp_sockinfo tcp = info.psi.soi_proto.pri_tcp;
      if (tcp.tcpsi_state == TSI_S_LISTEN &&
          ntohs((uint16_t)tcp.tcpsi_ini.insi_lport) == port) {
        found = 1;
        break;
      }
    }
    free(fds);
  }
  free(pids);
  return found;
}

int prde_group_listens(pid_t group, uint16_t port) {
  return processes_listen(PROC_PGRP_ONLY, (uint32_t)group, port);
}

int prde_postgres_ready(uint16_t port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) return 0;
  int ready = 0;
  int flags = fcntl(fd, F_GETFL);
  if (flags == -1 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1) goto done;
  int yes = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) == -1) goto done;
  struct sockaddr_in address = {.sin_len = sizeof(address),
                                .sin_family = AF_INET,
                                .sin_port = htons(port),
                                .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
  if (result == -1 && errno != EINPROGRESS) goto done;
  struct pollfd event = {.fd = fd, .events = POLLOUT};
  if (poll(&event, 1, 250) <= 0) goto done;
  int error = 0;
  socklen_t length = sizeof(error);
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == -1 || error) goto done;
  // PostgreSQL answers SSLRequest before authentication, proving the tunnel works.
  const unsigned char request[] = {0, 0, 0, 8, 4, 210, 22, 47};
  if (send(fd, request, sizeof(request), 0) != sizeof(request)) goto done;
  event.events = POLLIN;
  if (poll(&event, 1, 250) <= 0) goto done;
  unsigned char response;
  ready = recv(fd, &response, 1, 0) == 1 && (response == 'S' || response == 'N');
 done:
  if (close(fd) == -1) return 0;
  return ready;
}
