// Stress test v2 - prevent compile-time optimization
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;
typedef long long int64_t;

__attribute__((import_module("wasi_snapshot_preview1"), import_name("fd_write")))
int fd_write(int fd, const void *iovs, int iovs_len, int *nwritten);
__attribute__((import_module("wasi_snapshot_preview1"), import_name("proc_exit")))
void proc_exit(int code);
__attribute__((import_module("wasi_snapshot_preview1"), import_name("clock_time_get")))
int clock_time_get(int id, int64_t precision, int64_t *time);
__attribute__((import_module("wasi_snapshot_preview1"), import_name("random_get")))
int random_get(void *buf, int buf_len);

typedef struct { const unsigned char *buf; unsigned int buf_len; } ciovec_t;

__attribute__((noinline))
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
    for (int i = len; i < 32; i++) print(" ");
    print_num(us);
    print(" us  (");
    print_num(result);
    print(")\n");
}

// Volatile to prevent optimization
static volatile int64_t sink;

// ─── 1. Memory streaming (volatile sink) ───
#define STREAM_SIZE 4000000
static int stream_a[STREAM_SIZE];
static int stream_b[STREAM_SIZE];

__attribute__((noinline))
static int64_t stream_test(void) {
    for (int i = 0; i < STREAM_SIZE; i++) {
        stream_a[i] = i * 7;
        stream_b[i] = i * 13;
    }
    int64_t sum = 0;
    for (int iter = 0; iter < 10; iter++) {
        for (int i = 0; i < STREAM_SIZE; i++) {
            sum += stream_a[i] + stream_b[i];
        }
    }
    return sum;
}

// ─── 2. Integer ops (data-dependent) ───
__attribute__((noinline))
static int64_t int_ops(int n, int seed) {
    int64_t a = seed;
    int64_t b = seed * 3;
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        int64_t x = (a * 1103515245 + 12345) & 0x7FFFFFFF;
        int64_t y = (b * 1664525 + 1013904223) & 0x7FFFFFFF;
        sum += (x + y) ^ (x - y);
        sum += (x * y) >> 16;
        a = x;
        b = y;
    }
    return sum;
}

// ─── 3. Division (non-constant divisor) ───
__attribute__((noinline))
static int64_t div_ops(int n, int base) {
    int64_t sum = 0;
    for (int i = 1; i < n; i++) {
        int divisor = (base + i) & 0xFFF;
        if (divisor == 0) divisor = 1;
        sum += (i * 1234567) / divisor;
        sum += (i * 1234567) % divisor;
    }
    return sum;
}

// ─── 4. Float64 ops (data-dependent) ───
__attribute__((noinline))
static double float_ops(int n, double seed) {
    double sum = 0.0;
    double x = seed;
    for (int i = 1; i < n; i++) {
        double y = x * 1.000001 + 0.000001;
        sum += y * y;
        sum += y / (i + 1);
        x = y;
    }
    return sum;
}

// ─── 5. Call chain (forced via volatile) ───
__attribute__((noinline)) static int cf0(int x) { return x + 1; }
__attribute__((noinline)) static int cf1(int x) { return cf0(x) + 1; }
__attribute__((noinline)) static int cf2(int x) { return cf1(x) + 1; }
__attribute__((noinline)) static int cf3(int x) { return cf2(x) + 1; }
__attribute__((noinline)) static int cf4(int x) { return cf3(x) + 1; }
__attribute__((noinline)) static int cf5(int x) { return cf4(x) + 1; }
__attribute__((noinline)) static int cf6(int x) { return cf5(x) + 1; }
__attribute__((noinline)) static int cf7(int x) { return cf6(x) + 1; }
__attribute__((noinline)) static int cf8(int x) { return cf7(x) + 1; }
__attribute__((noinline)) static int cf9(int x) { return cf8(x) + 1; }

__attribute__((noinline))
static int64_t call_chain(int n, int start) {
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        sum += cf9(start + i);
    }
    return sum;
}

// ─── 6. i64 rotations and shifts ───
__attribute__((noinline))
static int64_t i64_rot(int n, uint64_t seed) {
    uint64_t a = seed;
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        a = (a << 13) | (a >> 51);  // rotl 13
        sum += (int64_t)a;
        a = (a >> 7) | (a << 57);   // rotr 7
        sum += (int64_t)a;
        a ^= a >> 17;
        sum += (int64_t)a;
    }
    return sum;
}

// ─── 7. Branch misprediction ───
__attribute__((noinline))
static int64_t branch_pred(int n, int seed) {
    int64_t sum = 0;
    uint32_t state = seed;
    for (int i = 0; i < n; i++) {
        state = state * 1103515245 + 12345;
        int x = (state >> 8) & 0xF;
        // Hard to predict branches
        if (x < 8) sum += x * 2;
        else sum -= x;
        if (x & 1) sum += i;
        else sum -= i;
        if (x > 10) sum *= 2;
    }
    return sum;
}

// ─── 8. Memory latency (pointer chasing) ───
#define CHASE_SIZE 100000
static int chase_arr[CHASE_SIZE];

__attribute__((noinline))
static int64_t mem_latency(int n) {
    // Initialize with permutation
    for (int i = 0; i < CHASE_SIZE; i++) chase_arr[i] = (i + 1) % CHASE_SIZE;
    chase_arr[CHASE_SIZE - 1] = 0;
    
    int64_t sum = 0;
    int idx = 0;
    for (int i = 0; i < n; i++) {
        idx = chase_arr[idx];
        sum += idx;
    }
    return sum;
}

// ─── 9. Global variable stress ───
static int g1, g2, g3, g4, g5;

__attribute__((noinline))
static int global_stress(int n) {
    g1 = 1; g2 = 2; g3 = 3; g4 = 4; g5 = 5;
    int sum = 0;
    for (int i = 0; i < n; i++) {
        g1 += g2;
        g2 += g3;
        g3 += g4;
        g4 += g5;
        g5 += g1;
        sum += g1 + g2 + g3 + g4 + g5;
    }
    return sum;
}

void _start(void) {
    int64_t t0, t1;
    int64_t seed = 0xDEADBEEF;  // Fixed seed for reproducibility
    
    print("WASM Stress Test v2 (anti-optimization)\n");
    print("========================================\n\n");
    
    t0 = now_us(); int64_t r1 = stream_test(); t1 = now_us();
    bench("stream(4M x10)", t1-t0, r1);
    
    t0 = now_us(); int64_t r2 = int_ops(10000000, seed); t1 = now_us();
    bench("int_ops(10M)", t1-t0, r2);
    
    t0 = now_us(); int64_t r3 = div_ops(1000000, seed); t1 = now_us();
    bench("div_ops(1M)", t1-t0, r3);
    
    t0 = now_us(); double r4 = float_ops(1000000, (double)seed); t1 = now_us();
    bench("float_ops(1M)", t1-t0, (int64_t)(r4 * 1000));
    
    t0 = now_us(); int64_t r5 = call_chain(10000000, seed); t1 = now_us();
    bench("call_chain(10M)", t1-t0, r5);
    
    t0 = now_us(); int64_t r6 = i64_rot(10000000, seed); t1 = now_us();
    bench("i64_rot(10M)", t1-t0, r6);
    
    t0 = now_us(); int64_t r7 = branch_pred(10000000, seed); t1 = now_us();
    bench("branch_pred(10M)", t1-t0, r7);
    
    t0 = now_us(); int64_t r8 = mem_latency(10000000); t1 = now_us();
    bench("mem_latency(10M)", t1-t0, r8);
    
    t0 = now_us(); int r9 = global_stress(10000000); t1 = now_us();
    bench("global_stress(10M)", t1-t0, r9);
    
    proc_exit(0);
}
