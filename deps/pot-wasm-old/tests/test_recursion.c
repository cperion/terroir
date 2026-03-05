// Recursion stress test
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

static int my_strlen(const char *s) { int n = 0; while (s[n]) n++; return n; }
static void print(const char *s) {
    ciovec_t iov = { (const unsigned char *)s, my_strlen(s) };
    int nw; fd_write(1, &iov, 1, &nw);
}
static void print_num(int64_t n) {
    char buf[24]; int i = 23; buf[i] = 0;
    int neg = 0;
    if (n < 0) { neg = 1; n = -n; }
    if (n == 0) buf[--i] = '0';
    while (n > 0) { buf[--i] = '0' + (n % 10); n /= 10; }
    if (neg) buf[--i] = '-';
    print(&buf[i]);
}
static int64_t now_us(void) {
    int64_t t; clock_time_get(1, 1, &t); return t / 1000;
}
static void bench(const char *name, int64_t us, int64_t result) {
    print("  ");
    print(name);
    int len = my_strlen(name);
    for (int i = len; i < 28; i++) print(" ");
    print_num(us);
    print(" us  (");
    print_num(result);
    print(")\n");
}

// Classic fibonacci
__attribute__((noinline))
static int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

// Tail recursion (could be optimized)
__attribute__((noinline))
static int tail_sum(int n, int acc) {
    if (n <= 0) return acc;
    return tail_sum(n - 1, acc + n);
}

// Mutual recursion
__attribute__((noinline)) static int is_even(int n);
__attribute__((noinline)) static int is_odd(int n);

__attribute__((noinline))
static int is_even(int n) {
    if (n == 0) return 1;
    return is_odd(n - 1);
}

__attribute__((noinline))
static int is_odd(int n) {
    if (n == 0) return 0;
    return is_even(n - 1);
}

// Tree recursion (like parsing)
__attribute__((noinline))
static int tree_depth(int depth) {
    if (depth <= 0) return 0;
    return 1 + tree_depth(depth - 1) + tree_depth(depth - 1) - tree_depth(depth - 1);
}

// Ackermann (very deep recursion)
__attribute__((noinline))
static int ack(int m, int n) {
    if (m == 0) return n + 1;
    if (n == 0) return ack(m - 1, 1);
    return ack(m - 1, ack(m, n - 1));
}

// Sum with many parameters
__attribute__((noinline))
static int sum_params(int a, int b, int c, int d, int e) {
    if (a <= 0) return b + c + d + e;
    return sum_params(a - 1, b + 1, c + 2, d + 3, e + 4);
}

void _start(void) {
    int64_t t0, t1;
    
    print("Recursion Benchmark\n");
    print("===================\n\n");
    
    t0 = now_us(); int r1 = fib(40); t1 = now_us();
    bench("fib(40)", t1-t0, r1);
    
    t0 = now_us(); int r2 = tail_sum(500, 0); t1 = now_us();
    bench("tail_sum(500)", t1-t0, r2);
    
    t0 = now_us(); int r3 = 0; for (int i = 0; i < 10000; i++) r3 += is_even(100); t1 = now_us();
    bench("mutual_recur(10K)", t1-t0, r3);
    
    t0 = now_us(); int r4 = tree_depth(15); t1 = now_us();
    bench("tree_depth(15)", t1-t0, r4);
    
    t0 = now_us(); int r5 = ack(3, 10); t1 = now_us();
    bench("ack(3,10)", t1-t0, r5);
    
    t0 = now_us(); int r6 = sum_params(500, 0, 0, 0, 0); t1 = now_us();
    bench("sum_params(500)", t1-t0, r6);
    
    proc_exit(0);
}
