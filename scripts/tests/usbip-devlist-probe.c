#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define PROBE_TIMEOUT_MS 5000
#define USBIP_VERSION 0x0111
#define OP_REQ_DEVLIST 0x8005
#define OP_REP_DEVLIST 0x0005

static int64_t monotonic_ms(void)
{
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return -1;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static int wait_fd(int fd, short events, int64_t deadline)
{
    for (;;) {
        const int64_t now = monotonic_ms();
        if (now < 0) return -1;
        const int64_t remaining = deadline - now;
        if (remaining <= 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        struct pollfd item = { .fd = fd, .events = events, .revents = 0 };
        const int result = poll(&item, 1, (int)remaining);
        if (result > 0) {
            if ((item.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0 &&
                (item.revents & events) == 0) {
                errno = ECONNRESET;
                return -1;
            }
            return 0;
        }
        if (result == 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        if (errno != EINTR) return -1;
    }
}

static int connect_numeric(const char *host, const char *port, int family)
{
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = family;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
    struct addrinfo *addresses = NULL;
    const int lookup = getaddrinfo(host, port, &hints, &addresses);
    if (lookup != 0) {
        fprintf(stderr, "numeric address error: %s\n", gai_strerror(lookup));
        return -1;
    }

    int connected = -1;
    int last_error = EHOSTUNREACH;
    for (struct addrinfo *item = addresses; item != NULL; item = item->ai_next) {
        const int fd = socket(item->ai_family, item->ai_socktype, item->ai_protocol);
        if (fd < 0) {
            last_error = errno;
            continue;
        }
        const int old_flags = fcntl(fd, F_GETFL, 0);
        if (old_flags < 0 || fcntl(fd, F_SETFL, old_flags | O_NONBLOCK) < 0) {
            last_error = errno;
            close(fd);
            continue;
        }
        int status = connect(fd, item->ai_addr, item->ai_addrlen);
        if (status < 0 && errno == EINPROGRESS) {
            const int64_t start = monotonic_ms();
            if (start >= 0 && wait_fd(fd, POLLOUT, start + PROBE_TIMEOUT_MS) == 0) {
                int socket_error = 0;
                socklen_t size = sizeof(socket_error);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error, &size) == 0 && socket_error == 0) {
                    connected = fd;
                    break;
                }
                last_error = socket_error != 0 ? socket_error : errno;
            } else {
                last_error = errno;
            }
        } else if (status == 0) {
            connected = fd;
            break;
        } else {
            last_error = errno;
        }
        close(fd);
    }
    freeaddrinfo(addresses);
    if (connected < 0) errno = last_error;
    return connected;
}

static int send_all_bounded(int fd, const uint8_t *bytes, size_t length)
{
    const int64_t start = monotonic_ms();
    if (start < 0) return -1;
    const int64_t deadline = start + PROBE_TIMEOUT_MS;
    size_t sent = 0;
    while (sent < length) {
        const ssize_t count = send(fd, bytes + sent, length - sent, 0);
        if (count > 0) {
            sent += (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (wait_fd(fd, POLLOUT, deadline) == 0) continue;
        }
        return -1;
    }
    return 0;
}

static int receive_exact_bounded(int fd, uint8_t *bytes, size_t length)
{
    const int64_t start = monotonic_ms();
    if (start < 0) return -1;
    const int64_t deadline = start + PROBE_TIMEOUT_MS;
    size_t received = 0;
    while (received < length) {
        const ssize_t count = recv(fd, bytes + received, length - received, 0);
        if (count > 0) {
            received += (size_t)count;
            continue;
        }
        if (count == 0) {
            errno = ECONNRESET;
            return -1;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (wait_fd(fd, POLLIN, deadline) == 0) continue;
        }
        return -1;
    }
    return 0;
}

static uint16_t read_be16(const uint8_t *bytes)
{
    return (uint16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
}

static uint32_t read_be32(const uint8_t *bytes)
{
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
        ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static int parse_port(const char *text)
{
    char *end = NULL;
    errno = 0;
    const long value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < 1 || value > 65535) return -1;
    return (int)value;
}

int main(int argc, char **argv)
{
    (void)signal(SIGPIPE, SIG_IGN);
    if (argc != 4 || (strcmp(argv[1], "4") != 0 && strcmp(argv[1], "6") != 0)) {
        fprintf(stderr, "usage: %s <4|6> <numeric-address> <port>\n", argv[0]);
        return 2;
    }
    const int family = strcmp(argv[1], "4") == 0 ? AF_INET : AF_INET6;
    const int port = parse_port(argv[3]);
    if (port < 0) {
        fprintf(stderr, "invalid port: %s\n", argv[3]);
        return 2;
    }

    const int fd = connect_numeric(argv[2], argv[3], family);
    if (fd < 0) {
        perror("connect");
        return 1;
    }

    const int old_flags = fcntl(fd, F_GETFL, 0);
    if (old_flags < 0 || fcntl(fd, F_SETFL, old_flags | O_NONBLOCK) < 0) {
        perror("set nonblocking socket");
        close(fd);
        return 1;
    }

    /* USB/IP 1.1.1 OP_REQ_DEVLIST: 8-byte op header, no payload. */
    const uint8_t request[8] = { 0x01, 0x11, 0x80, 0x05, 0x00, 0x00, 0x00, 0x00 };
    uint8_t response[12];
    if (send_all_bounded(fd, request, sizeof(request)) != 0) {
        perror("send DEVLIST request");
        close(fd);
        return 1;
    }
    if (receive_exact_bounded(fd, response, sizeof(response)) != 0) {
        perror("receive DEVLIST response header");
        close(fd);
        return 1;
    }
    close(fd);

    const uint32_t status = read_be32(&response[4]);
    if (read_be16(&response[0]) != USBIP_VERSION || read_be16(&response[2]) != OP_REP_DEVLIST || status != 0) {
        fprintf(stderr, "invalid DEVLIST reply: version=0x%04x op=0x%04x status=%u\n",
            read_be16(&response[0]), read_be16(&response[2]), status);
        return 1;
    }
    const uint32_t count = read_be32(&response[8]);
    printf("family=IPv%d port=%d count=%u\n", family == AF_INET ? 4 : 6, port, count);
    return 0;
}
