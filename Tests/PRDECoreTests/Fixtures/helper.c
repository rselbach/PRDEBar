#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int record_pid(const char *role, const char *kind) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/%s-%s", getenv("PRDE_TEST_DIRECTORY"), role, kind);
  FILE *file = fopen(path, "w");
  if (!file) return 1;
  if (fprintf(file, "%d", getpid()) < 0) {
    fclose(file);
    return 1;
  }
  return fclose(file) != 0;
}

int main(int argc, char **argv) {
  if (argc < 4) return 2;
  const int proxy = strcmp(argv[2], "proxy") == 0;
  const char *role = proxy ? "proxy" : "postgres";
  const char *mode = getenv("PRDE_TEST_MODE");
  if (!mode) mode = "normal";
  if (record_pid(role, "parent")) return 3;
  if (strcmp(mode, "early-exit") == 0 ||
      (!proxy && strcmp(mode, "postgres-exit") == 0)) {
    for (int i = 0; i < 100000; i++) fputs("Greendale diagnostic\n", stderr);
    return 23;
  }
  const pid_t leader = getpid();
  int child = fork();
  if (child < 0) return 4;
  if (child > 0) {
    for (;;) pause();
  }
  if (record_pid(role, "child")) return 5;
  child = fork();
  if (child < 0) return 4;
  if (child > 0) {
    for (;;) pause();
  }
  if (record_pid(role, "descendant")) return 5;
  if (strcmp(mode, "ignore-term") == 0) signal(SIGTERM, SIG_IGN);
  if (proxy && strcmp(mode, "slow-proxy") == 0) sleep(10);
  int port = proxy ? atoi(getenv("PRDE_TEST_PROXY_PORT")) : atoi(argv[3]);
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) return 6;
  int yes = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes)) == -1) return 7;
  struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET,
      .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  if (bind(fd, (struct sockaddr *)&address, sizeof(address)) == -1 || listen(fd, 8) == -1) return 8;
  for (;;) {
    struct pollfd event = {.fd = fd, .events = POLLIN};
    if (poll(&event, 1, 100) < 0 && errno != EINTR) return 9;
    char path[4096];
    snprintf(path, sizeof(path), "%s/exit-%s", getenv("PRDE_TEST_DIRECTORY"), role);
    if (access(path, F_OK) == 0) {
      if (kill(leader, SIGTERM) == -1) return 10;
      return 24;
    }
    snprintf(path, sizeof(path), "%s/unresponsive-%s", getenv("PRDE_TEST_DIRECTORY"), role);
    int unresponsive = access(path, F_OK) == 0;
    if (!(event.revents & POLLIN)) continue;
    int client = accept(fd, NULL, NULL);
    if (client == -1) continue;
    struct timeval timeout = {.tv_sec = 1};
    if (setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == -1) return 11;
    if (setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == -1) return 12;
    if (setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) == -1) return 13;
    char request[4096];
    ssize_t count = recv(client, request, sizeof(request), 0);
    if (count > 0 && !unresponsive) {
      const char *response = proxy
          ? "HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\n\"127.0.0.1:4647\""
          : "N";
      if (strcmp(mode, "no-postgres-response") != 0 || proxy) {
        if (send(client, response, strlen(response), 0) == -1 && errno != EPIPE) return 14;
      }
    }
    if (close(client) == -1) return 15;
  }
}
