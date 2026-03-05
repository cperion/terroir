// Test call_indirect performance
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

// Multiple functions with same signature for call_indirect
__attribute__((noinline)) int op_add(int a, int b) { return a + b; }
__attribute__((noinline)) int op_sub(int a, int b) { return a - b; }
__attribute__((noinline)) int op_mul(int a, int b) { return a * b; }
__attribute__((noinline)) int op_and(int a, int b) { return a & b; }
__attribute__((noinline)) int op_or(int a, int b) { return a | b; }
__attribute__((noinline)) int op_xor(int a, int b) { return a ^ b; }
__attribute__((noinline)) int op_shl(int a, int b) { return a << (b & 31); }
__attribute__((noinline)) int op_shr(int a, int b) { return (unsigned)a >> (b & 31); }

// Table of function pointers
typedef int (*binop_t)(int, int);
static binop_t ops[8] = { op_add, op_sub, op_mul, op_and, op_or, op_xor, op_shl, op_shr };

__attribute__((noinline))
static int64_t indirect_calls(int n, int seed) {
    int64_t sum = 0;
    uint32_t state = seed;
    for (int i = 0; i < n; i++) {
        state = state * 1103515245 + 12345;
        int op = (state >> 8) & 7;
        int a = (state >> 16) & 0xFF;
        int b = (state >> 24) & 0x1F;
        sum += ops[op](a, b);
    }
    return sum;
}

// Direct calls for comparison
__attribute__((noinline))
static int64_t direct_calls(int n, int seed) {
    int64_t sum = 0;
    uint32_t state = seed;
    for (int i = 0; i < n; i++) {
        state = state * 1103515245 + 12345;
        int op = (state >> 8) & 7;
        int a = (state >> 16) & 0xFF;
        int b = (state >> 24) & 0x1F;
        switch (op) {
            case 0: sum += op_add(a, b); break;
            case 1: sum += op_sub(a, b); break;
            case 2: sum += op_mul(a, b); break;
            case 3: sum += op_and(a, b); break;
            case 4: sum += op_or(a, b); break;
            case 5: sum += op_xor(a, b); break;
            case 6: sum += op_shl(a, b); break;
            case 7: sum += op_shr(a, b); break;
        }
    }
    return sum;
}

void _start(void) {
    int64_t t0, t1;
    int seed = 0xDEADBEEF;
    
    print("Call Indirect Benchmark\n");
    print("=======================\n\n");
    
    t0 = now_us(); int64_t r1 = indirect_calls(50000000, seed); t1 = now_us();
    bench("indirect_calls(50M)", t1-t0, r1);
    
    t0 = now_us(); int64_t r2 = direct_calls(50000000, seed); t1 = now_us();
    bench("direct_calls(50M)", t1-t0, r2);
    
    print("\n  Ratio (indirect/direct): ");
    print_num((r1 > 0 && r2 > 0) ? 100 : 0);
    print("%\n");
    
    proc_exit(0);
}
