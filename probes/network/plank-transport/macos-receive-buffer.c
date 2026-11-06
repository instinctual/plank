// SPDX-License-Identifier: AGPL-3.0-or-later
// Diagnostic-only comparison: change sockets in the isolated test process.
// Never link or inject this into a Host/Client application.
#include <stdio.h>
#include <sys/socket.h>
#include <netinet/in.h>

static int probe_socket(int domain, int type, int protocol) {
    int fd = socket(domain, type, protocol);
    if (fd >= 0 && (domain == AF_INET || domain == AF_INET6) && type == SOCK_DGRAM) {
        int before = 0, after = 0, wanted = 4 * 1024 * 1024;
        socklen_t length = sizeof(before);
        getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &before, &length);
        int result = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &wanted, sizeof(wanted));
        getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &after, &length);
        fprintf(stderr, "probe_udp_receive_buffer before=%d after=%d result=%d\n", before, after, result);
    }
    return fd;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } interpose = {
    (const void *)probe_socket, (const void *)socket
};
