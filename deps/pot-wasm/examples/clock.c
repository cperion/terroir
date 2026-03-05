// Clock + computation timing demo for POT
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;
typedef long long int64_t;

__attribute__((import_module("wasi_snapshot_preview1"), import_name("fd_write")))
int fd_write(int fd, const void *iovs, int iovs_len, int *nwritten);
__attribute__((import_module("wasi_snapshot_preview1"), import_name("proc_exit")))
void proc_exit(int code);
__attribute__((import_module("wasi_snapshot_preview1"), import_name("clock_time_get")))
int clock_time_get(int id, int64_t precision, int64_t *time);

typedef struct { const unsigned char *buf; unsigned int buf_len; } ciovec_t;

static int strlen(const char *s) { int n = 0; while (s[n]) n++; return n; }

static void print(const char *s) {
    ciovec_t iov = { (const unsigned char *)s, strlen(s) };
    int nw;
    fd_write(1, &iov, 1, &nw);
}

static void print_num(int64_t n) {
    char buf[24];
    int i = 23;
    buf[i] = 0;
    if (n == 0) { buf[--i] = '0'; }
    else { while (n > 0) { buf[--i] = '0' + (n % 10); n /= 10; } }
    print(&buf[i]);
}

static int fib_rec(int n) {
    if (n <= 1) return n;
    return fib_rec(n - 1) + fib_rec(n - 2);
}

void _start(void) {
    int64_t t0, t1;

    print("Timing fib_rec(35)...\n");
    clock_time_get(1, 1, &t0);  // CLOCK_MONOTONIC
    int result = fib_rec(35);
    clock_time_get(1, 1, &t1);

    print("  result = ");
    print_num(result);
    print("\n  time   = ");
    print_num((t1 - t0) / 1000);
    print(" us\n");

    proc_exit(0);
}
