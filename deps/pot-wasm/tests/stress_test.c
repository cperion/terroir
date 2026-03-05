// Stress test for WASM runtimes
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

// ─── 1. Deep recursion - stack stress ───
__attribute__((noinline))
static int deep_rec(int n, int acc) {
    if (n <= 0) return acc;
    return deep_rec(n - 1, acc + n);
}

// ─── 2. Memory bandwidth - streaming ───
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

// ─── 3. Random memory access - cache stress ───
#define RAND_SIZE 100000
static int rand_arr[RAND_SIZE];

__attribute__((noinline))
static int64_t random_access(void) {
    for (int i = 0; i < RAND_SIZE; i++) rand_arr[i] = i;
    // Permutation
    uint32_t seed = 12345;
    for (int i = RAND_SIZE - 1; i > 0; i--) {
        seed = seed * 1103515245 + 12345;
        int j = (seed >> 8) % (i + 1);
        int t = rand_arr[i]; rand_arr[i] = rand_arr[j]; rand_arr[j] = t;
    }
    int64_t sum = 0;
    for (int iter = 0; iter < 100; iter++) {
        int idx = 0;
        for (int i = 0; i < RAND_SIZE; i++) {
            sum += rand_arr[idx];
            idx = rand_arr[idx];
        }
    }
    return sum;
}

// ─── 4. Integer division stress (POT has special handling) ───
__attribute__((noinline))
static int64_t div_stress(int n) {
    int64_t sum = 0;
    for (int i = 1; i < n; i++) {
        sum += (i * 1234567) / i;
        sum += (i * 1234567) % i;
    }
    return sum;
}

// ─── 5. Float64 heavy - trig simulation ───
__attribute__((noinline))
static double float_heavy(int n) {
    double sum = 0.0;
    double pi = 3.14159265358979;
    for (int i = 1; i < n; i++) {
        double x = (double)i * 0.001;
        // Taylor series for sin/cos approximations (avoid libc)
        double x2 = x * x;
        double sin_x = x - x*x2/6.0 + x2*x2*x/120.0;
        double cos_x = 1.0 - x2/2.0 + x2*x2/24.0;
        sum += sin_x * sin_x + cos_x * cos_x; // should be ~1
    }
    return sum;
}

// ─── 6. Many small functions - call overhead ───
__attribute__((noinline)) static int f0(int x) { return x + 1; }
__attribute__((noinline)) static int f1(int x) { return f0(x) + 1; }
__attribute__((noinline)) static int f2(int x) { return f1(x) + 1; }
__attribute__((noinline)) static int f3(int x) { return f2(x) + 1; }
__attribute__((noinline)) static int f4(int x) { return f3(x) + 1; }
__attribute__((noinline)) static int f5(int x) { return f4(x) + 1; }
__attribute__((noinline)) static int f6(int x) { return f5(x) + 1; }
__attribute__((noinline)) static int f7(int x) { return f6(x) + 1; }
__attribute__((noinline)) static int f8(int x) { return f7(x) + 1; }
__attribute__((noinline)) static int f9(int x) { return f8(x) + 1; }

__attribute__((noinline))
static int64_t call_overhead(int n) {
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        sum += f9(i);
    }
    return sum;
}

// ─── 7. i64 operations stress ───
__attribute__((noinline))
static int64_t i64_stress(int n) {
    int64_t a = 0x123456789ABCDEF0LL;
    int64_t b = 0xFEDCBA9876543210LL;
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        sum += (a + b) ^ (a - b);
        sum += (a * (i + 1)) >> 16;
        a = (a << 1) | (a >> 63);
        b = b ^ a;
    }
    return sum;
}

// ─── 8. Control flow density - many branches ───
__attribute__((noinline))
static int branch_heavy(int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        int x = i & 0xF;
        if (x == 0) sum += 1;
        else if (x == 1) sum += 2;
        else if (x == 2) sum += 3;
        else if (x == 3) sum += 4;
        else if (x == 4) sum += 5;
        else if (x == 5) sum += 6;
        else if (x == 6) sum += 7;
        else if (x == 7) sum += 8;
        else if (x == 8) sum += 9;
        else if (x == 9) sum += 10;
        else if (x == 10) sum += 11;
        else if (x == 11) sum += 12;
        else if (x == 12) sum += 13;
        else if (x == 13) sum += 14;
        else if (x == 14) sum += 15;
        else sum += 16;
    }
    return sum;
}

void _start(void) {
    int64_t t0, t1;
    
    print("WASM Stress Test\n");
    print("================\n\n");
    
    t0 = now_us(); int64_t r1 = deep_rec(500, 0); t1 = now_us();
    bench("deep_rec(500)", t1-t0, r1);
    
    t0 = now_us(); int64_t r2 = stream_test(); t1 = now_us();
    bench("stream(4M x10)", t1-t0, r2);
    
    t0 = now_us(); int64_t r3 = random_access(); t1 = now_us();
    bench("random_access(100K x100)", t1-t0, r3);
    
    t0 = now_us(); int64_t r4 = div_stress(1000000); t1 = now_us();
    bench("div_stress(1M)", t1-t0, r4);
    
    t0 = now_us(); double r5 = float_heavy(1000000); t1 = now_us();
    bench("float_heavy(1M)", t1-t0, (int64_t)(r5 * 1000));
    
    t0 = now_us(); int64_t r6 = call_overhead(10000000); t1 = now_us();
    bench("call_overhead(10M)", t1-t0, r6);
    
    t0 = now_us(); int64_t r7 = i64_stress(10000000); t1 = now_us();
    bench("i64_stress(10M)", t1-t0, r7);
    
    t0 = now_us(); int r8 = branch_heavy(10000000); t1 = now_us();
    bench("branch_heavy(10M)", t1-t0, r8);
    
    proc_exit(0);
}
