/* The system tail for the backwards and following jobs.
 *
 *   follow-command reverse PATH       tail -r PATH, every line last first
 *   follow-command follow DIR PATH    tail -F: catch-up over PATH, then lines
 *                                     appended to (and the path rotated under)
 *                                     a file in DIR, each timed until tail
 *                                     prints it.
 *
 * tail hands back bytes through a pipe; it parses nothing. */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int smoke(void) { const char *s = getenv("BENCH_SMOKE"); return s && !strcmp(s, "1"); }
static double now_ns(void) {
    static unsigned ticks;
    if (smoke()) return ++ticks;
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec;
}
static const char *tail_tool(void) { return getenv("TAIL") ? getenv("TAIL") : "tail"; }
static void die(const char *what) { perror(what); exit(1); }

static pid_t spawn(char *const argv[], int *out) {
    int fds[2]; if (pipe(fds)) die("pipe");
    pid_t p = fork(); if (p < 0) die("fork");
    if (p == 0) { dup2(fds[1], 1); close(fds[0]); close(fds[1]); execvp(argv[0], argv); _exit(127); }
    close(fds[1]); *out = fds[0]; return p;
}
static void stop(pid_t p, int fd) { kill(p, SIGTERM); close(fd); waitpid(p, NULL, 0); }

/* Reads from fd until `want` more newlines have arrived; counts bytes. */
static char pending[1 << 16]; static size_t pending_len;
static uint64_t read_lines(int fd, uint64_t want, uint64_t *bytes) {
    uint64_t got = 0;
    while (got < want) {
        for (size_t i = 0; i < pending_len && got < want; i++) {
            if (pending[i] == '\n') {
                got++;
                if (got == want) { memmove(pending, pending + i + 1, pending_len - i - 1); pending_len -= i + 1; return got; }
            } else if (bytes) (*bytes)++;
        }
        pending_len = 0;
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int r = poll(&pfd, 1, 30000);
        if (r == 0) { fprintf(stderr, "tail delivered nothing for 30 s\n"); exit(1); }
        if (r < 0) die("poll");
        ssize_t n = read(fd, pending, sizeof pending);
        if (n <= 0) { fprintf(stderr, "tail ended early\n"); exit(1); }
        pending_len = (size_t)n;
    }
    return got;
}

static uint64_t count_lines(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) die(path);
    uint64_t n = 0; int c; while ((c = getc(f)) != EOF) if (c == '\n') n++;
    fclose(f); return n;
}

static void reverse(const char *path) {
    int reps = smoke() ? 1 : 5; uint64_t lines = 0, bytes = 0; double start = now_ns();
    uint64_t want = count_lines(path);
    for (int i = 0; i < reps; i++) {
        int fd; char *argv[] = { (char *)tail_tool(), "-r", (char *)path, NULL };
        pid_t p = spawn(argv, &fd); pending_len = 0;
        uint64_t b = 0; uint64_t got = read_lines(fd, want, &b);
        int status; close(fd); waitpid(p, &status, 0);
        if (!WIFEXITED(status) || WEXITSTATUS(status)) exit(1);
        if (i == 0) { lines = got; bytes = b; }
    }
    double ns = now_ns() - start;
    printf("bsd-tail\tbackward-raw\titems\t%.6f\titems/s\n", lines * reps * 1e9 / ns);
    printf("bsd-tail\tbackward-raw\tper_item\t%.6f\tns\n", ns / (lines * reps));
    printf("bsd-tail\tbackward-raw\tlines\t%llu\tchecksum\n", (unsigned long long)lines);
    printf("bsd-tail\tbackward-raw\tbytes\t%llu\tchecksum\n", (unsigned long long)bytes);
}

static const char line_bytes[] = "{\"id\":0,\"name\":\"user-3456\",\"count\":987654,\"meta\":{\"region\":\"eu\",\"score\":73},\"tags\":[\"jsonl\",\"benchmark\",\"g42\"],\"message\":\"abcdefghijabcdefghij\"}\n";

static void append_line(int fd) { if (write(fd, line_bytes, sizeof line_bytes - 1) != (ssize_t)(sizeof line_bytes - 1)) die("write"); }

static void follow(const char *dir, const char *path) {
    char file[4096], rotated[4096];
    /* Catch-up: every line already in the file. */
    {
        uint64_t want = count_lines(path); int fd;
        char *argv[] = { (char *)tail_tool(), "-n", "+1", "-F", (char *)path, NULL };
        double start = now_ns(); pid_t p = spawn(argv, &fd); pending_len = 0;
        uint64_t got = read_lines(fd, want, NULL); double ns = now_ns() - start; stop(p, fd);
        printf("bsd-tail\tfollow-catchup\titems\t%.6f\titems/s\n", got * 1e9 / ns);
        printf("bsd-tail\tfollow-catchup\tper_item\t%.6f\tns\n", ns / got);
        printf("bsd-tail\tfollow-catchup\tlines\t%llu\tchecksum\n", (unsigned long long)got);
    }
    /* Appends, one at a time, each timed until tail prints it. */
    {
        uint64_t n = smoke() ? 2 : 1000;
        snprintf(file, sizeof file, "%s/tail-append.jsonl", dir);
        int w = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (w < 0) die(file);
        int fd; char *argv[] = { (char *)tail_tool(), "-n", "+1", "-F", file, NULL };
        pid_t p = spawn(argv, &fd); pending_len = 0;
        append_line(w); read_lines(fd, 1, NULL); /* tail is watching */
        double total = 0;
        for (uint64_t i = 0; i < n; i++) { double t = now_ns(); append_line(w); read_lines(fd, 1, NULL); total += now_ns() - t; }
        stop(p, fd); close(w);
        printf("bsd-tail\tfollow-append\tlatency\t%.6f\tus\n", total / n / 1e3);
        printf("bsd-tail\tfollow-append\tlines\t%llu\tchecksum\n", (unsigned long long)n);
    }
    /* Rotation: the path renamed away and created again with one line. */
    {
        uint64_t n = smoke() ? 1 : 5;
        snprintf(file, sizeof file, "%s/tail-rotate.jsonl", dir);
        snprintf(rotated, sizeof rotated, "%s/tail-rotate.jsonl.1", dir);
        int w = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (w < 0) die(file);
        int fd; char *argv[] = { (char *)tail_tool(), "-n", "+1", "-F", file, NULL };
        pid_t p = spawn(argv, &fd); pending_len = 0;
        append_line(w); read_lines(fd, 1, NULL); close(w);
        double total = 0;
        for (uint64_t i = 0; i < n; i++) {
            if (rename(file, rotated)) die("rename");
            w = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (w < 0) die(file);
            double t = now_ns(); append_line(w); close(w);
            read_lines(fd, 1, NULL); total += now_ns() - t;
        }
        stop(p, fd);
        printf("bsd-tail\tfollow-rotate\tlatency\t%.6f\tus\n", total / n / 1e3);
        printf("bsd-tail\tfollow-rotate\tlines\t%llu\tchecksum\n", (unsigned long long)n);
    }
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    if (argc == 3 && !strcmp(argv[1], "reverse")) reverse(argv[2]);
    else if (argc == 4 && !strcmp(argv[1], "follow")) follow(argv[2], argv[3]);
    else return 2;
    return 0;
}
