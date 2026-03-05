// i64 operations stress test
typedef int int32_t;
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

// i64 arithmetic
__attribute__((noinline))
static int64_t i64_arith(int n, int64_t seed) {
    int64_t a = seed;
    int64_t b = seed ^ 0xDEADBEEFCAFEBABE;
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        sum += a + b;
        sum += a - b;
        sum += a * ((i & 7) + 1);
        a = (a << 1) | (a >> 63);
        b = b ^ a;
    }
    return sum;
}

// i64 bitwise
__attribute__((noinline))
static int64_t i64_bitwise(int n, int64_t seed) {
    int64_t a = seed;
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        int64_t b = a ^ (a >> 17);
        sum += a & b;
        sum += a | b;
        sum += a ^ b;
        sum += a << ((i & 31) + 1);
        sum += a >> ((i & 31) + 1);
        sum += (uint64_t)a >> ((i & 31) + 1);
        a = b;
    }
    return sum;
}

// i64 division (data-dependent)
__attribute__((noinline))
static int64_t i64_div(int n, int seed) {
    int64_t sum = 0;
    uint32_t state = seed;
    for (int i = 1; i < n; i++) {
        state = state * 1103515245 + 12345;
        int64_t divisor = (state >> 8) | 1;
        sum += (int64_t)(i * 1234567890123LL) / divisor;
        sum += (int64_t)(i * 1234567890123LL) % divisor;
        sum += (uint64_t)(i * 1234567890123ULL) / (uint64_t)divisor;
        sum += (uint64_t)(i * 1234567890123ULL) % (uint64_t)divisor;
    }
    return sum;
}

// i64 rotations
__attribute__((noinline))
static int64_t i64_rotations(int n, uint64_t seed) {
    uint64_t a = seed;
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        int c = i & 63;
        uint64_t r1 = (a << c) | (a >> (64 - c));
        uint64_t r2 = (a >> c) | (a << (64 - c));
        sum += (int64_t)r1 + (int64_t)r2;
        a = r1 ^ r2;
    }
    return sum;
}

// i64 comparisons
__attribute__((noinline))
static int i64_cmp(int n, int64_t seed) {
    int64_t a = seed;
    int count = 0;
    for (int i = 0; i < n; i++) {
        int64_t b = a + i;
        if (a == b) count++;
        if (a != b) count++;
        if (a < b) count++;
        if (a <= b) count++;
        if (a > b) count++;
        if (a >= b) count++;
        if ((uint64_t)a < (uint64_t)b) count++;
        if ((uint64_t)a <= (uint64_t)b) count++;
        if ((uint64_t)a > (uint64_t)b) count++;
        if ((uint64_t)a >= (uint64_t)b) count++;
        a = b;
    }
    return count;
}

// i64 conversions
__attribute__((noinline))
static int64_t i64_conv(int n, int seed) {
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        int32_t s = (int32_t)(seed + i);
        uint32_t u = (uint32_t)(seed + i);
        sum += (int64_t)s;
        sum += (int64_t)u;
        int64_t v = (int64_t)i * 0x123456789ABCDEFLL;
        sum += (int32_t)v;
        sum += (uint32_t)v;
    }
    return sum;
}

void _start(void) {
    int64_t t0, t1;
    int64_t seed = 0x123456789ABCDEF0LL;
    
    print("i64 Operations Benchmark\n");
    print("========================\n\n");
    
    t0 = now_us(); int64_t r1 = i64_arith(10000000, seed); t1 = now_us();
    bench("i64_arith(10M)", t1-t0, r1);
    
    t0 = now_us(); int64_t r2 = i64_bitwise(10000000, seed); t1 = now_us();
    bench("i64_bitwise(10M)", t1-t0, r2);
    
    t0 = now_us(); int64_t r3 = i64_div(1000000, 0xDEADBEEF); t1 = now_us();
    bench("i64_div(1M)", t1-t0, r3);
    
    t0 = now_us(); int64_t r4 = i64_rotations(10000000, seed); t1 = now_us();
    bench("i64_rotations(10M)", t1-t0, r4);
    
    t0 = now_us(); int r5 = i64_cmp(10000000, seed); t1 = now_us();
    bench("i64_cmp(10M)", t1-t0, r5);
    
    t0 = now_us(); int64_t r6 = i64_conv(10000000, 0xDEADBEEF); t1 = now_us();
    bench("i64_conv(10M)", t1-t0, r6);
    
    proc_exit(0);
}
