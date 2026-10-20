#ifndef PRDE_PROCESS_SUPPORT_H
#define PRDE_PROCESS_SUPPORT_H

#include <stdint.h>
#include <sys/types.h>

int prde_spawn(const char *path, char *const argv[], char *const envp[], pid_t *pid);
int prde_port_available(uint16_t port);
int prde_group_listens(pid_t group, uint16_t port);
int prde_postgres_ready(uint16_t port);

#endif
