// Floating point operations stress test
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

// f32 operations
__attribute__((noinline))
static float f32_ops(int n, float seed) {
    float a = seed;
    float sum = 0.0f;
    for (int i = 1; i < n; i++) {
        float b = a * 1.00001f + 0.00001f;
        sum += b + b;
        sum += b - a;
        sum += b * 0.5f;
        sum += b / (float)(i + 1);
        a = b;
    }
    return sum;
}

// f64 operations
__attribute__((noinline))
static double f64_ops(int n, double seed) {
    double a = seed;
    double sum = 0.0;
    for (int i = 1; i < n; i++) {
        double b = a * 1.0000000001 + 0.0000000001;
        sum += b + b;
        sum += b - a;
        sum += b * 0.5;
        sum += b / (double)(i + 1);
        a = b;
    }
    return sum;
}

// f32 comparisons
__attribute__((noinline))
static int f32_cmp(int n, float seed) {
    float a = seed;
    int count = 0;
    for (int i = 0; i < n; i++) {
        float b = a * 1.00001f;
        if (b > a) count++;
        if (b >= a) count++;
        if (b < a + 1.0f) count++;
        if (b <= a + 1.0f) count++;
        if (b == b) count++;  // always true (not NaN)
        if (b != a) count++;
        a = b;
    }
    return count;
}

// f64 comparisons
__attribute__((noinline))
static int f64_cmp(int n, double seed) {
    double a = seed;
    int count = 0;
    for (int i = 0; i < n; i++) {
        double b = a * 1.0000000001;
        if (b > a) count++;
        if (b >= a) count++;
        if (b < a + 1.0) count++;
        if (b <= a + 1.0) count++;
        if (b == b) count++;
        if (b != a) count++;
        a = b;
    }
    return count;
}

// Mixed precision
__attribute__((noinline))
static double mixed_precision(int n) {
    float f = 1.0f;
    double d = 1.0;
    double sum = 0.0;
    for (int i = 0; i < n; i++) {
        // Promote/demote
        d = (double)f;
        f = (float)d;
        sum += d + f;
    }
    return sum;
}

// Math functions (software implementations to test runtime)
static float fabsf_local(float x) { return x < 0 ? -x : x; }
static double fabs_local(double x) { return x < 0 ? -x : x; }
static float floorf_local(float x) { return (float)(int)x - (x < 0 && x != (float)(int)x ? 1 : 0); }
static float ceilf_local(float x) { return (float)(int)x + (x > 0 && x != (float)(int)x ? 1 : 0); }

__attribute__((noinline))
static float f32_unary(int n, float seed) {
    float sum = 0.0f;
    for (int i = 0; i < n; i++) {
        float x = seed + i * 0.001f;
        sum += fabsf_local(x);
        sum += floorf_local(x);
        sum += ceilf_local(x);
        sum += -x;
    }
    return sum;
}

void _start(void) {
    int64_t t0, t1;
    float sf = 1.234567f;
    double sd = 1.23456789012345;
    
    print("Floating Point Benchmark\n");
    print("========================\n\n");
    
    t0 = now_us(); float r1 = f32_ops(10000000, sf); t1 = now_us();
    bench("f32_ops(10M)", t1-t0, (int64_t)(r1 * 1000));
    
    t0 = now_us(); double r2 = f64_ops(10000000, sd); t1 = now_us();
    bench("f64_ops(10M)", t1-t0, (int64_t)(r2 * 1000));
    
    t0 = now_us(); int r3 = f32_cmp(10000000, sf); t1 = now_us();
    bench("f32_cmp(10M)", t1-t0, r3);
    
    t0 = now_us(); int r4 = f64_cmp(10000000, sd); t1 = now_us();
    bench("f64_cmp(10M)", t1-t0, r4);
    
    t0 = now_us(); double r5 = mixed_precision(10000000); t1 = now_us();
    bench("mixed_precision(10M)", t1-t0, (int64_t)(r5 * 1000));
    
    t0 = now_us(); float r6 = f32_unary(10000000, sf); t1 = now_us();
    bench("f32_unary(10M)", t1-t0, (int64_t)(r6 * 1000));
    
    proc_exit(0);
}
