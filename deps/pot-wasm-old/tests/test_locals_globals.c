// Locals and globals stress test
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

// Many locals
__attribute__((noinline))
static int64_t many_locals(int n) {
    int64_t a=1,b=2,c=3,d=4,e=5,f=6,g=7,h=8,i=9,j=10;
    int64_t k=11,l=12,m=13,n_=14,o=15,p=16,q=17,r=18,s=19,t=20;
    int64_t sum = 0;
    for (int iter = 0; iter < n; iter++) {
        sum += a + b + c + d + e;
        sum += f + g + h + i + j;
        sum += k + l + m + n_ + o;
        sum += p + q + r + s + t;
        a++; b++; c++; d++; e++;
        f++; g++; h++; i++; j++;
        k++; l++; m++; n_++; o++;
        p++; q++; r++; s++; t++;
    }
    return sum;
}

// Local get/set heavy
__attribute__((noinline))
static int64_t local_getset(int n) {
    int64_t x = 0;
    for (int i = 0; i < n; i++) {
        x = x + 1;
        x = x * 2;
        x = x - 1;
        x = x / 2;
    }
    return x;
}

// Global variables
static int64_t g1 = 1, g2 = 2, g3 = 3, g4 = 4, g5 = 5;

__attribute__((noinline))
static int64_t global_getset(int n) {
    int64_t sum = 0;
    for (int iter = 0; iter < n; iter++) {
        sum += g1 + g2 + g3 + g4 + g5;
        g1++; g2++; g3++; g4++; g5++;
    }
    return sum;
}

// Mixed local/global
__attribute__((noinline))
static int64_t mixed_local_global(int n) {
    int64_t l1 = 100, l2 = 200;
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        sum += l1 + g1;
        sum += l2 + g2;
        l1 = g3;
        l2 = g4;
        g1 = l1 + 1;
        g2 = l2 + 1;
    }
    return sum;
}

// Local tee pattern
__attribute__((noinline))
static int64_t local_tee_pattern(int n) {
    int64_t x = 0;
    for (int i = 0; i < n; i++) {
        x = (x + i) * 2;
        x = (x ^ i) + 1;
        x = (x | i) - 1;
    }
    return x;
}

// Many parameters
__attribute__((noinline))
static int64_t many_params(int n, int64_t p1, int64_t p2, int64_t p3, int64_t p4, int64_t p5,
                           int64_t p6, int64_t p7, int64_t p8, int64_t p9, int64_t p10) {
    int64_t sum = 0;
    for (int i = 0; i < n; i++) {
        sum += p1 + p2 + p3 + p4 + p5;
        sum += p6 + p7 + p8 + p9 + p10;
    }
    return sum;
}

void _start(void) {
    int64_t t0, t1;
    
    print("Locals/Globals Benchmark\n");
    print("========================\n\n");
    
    t0 = now_us(); int64_t r1 = many_locals(10000000); t1 = now_us();
    bench("many_locals(10M)", t1-t0, r1);
    
    t0 = now_us(); int64_t r2 = local_getset(100000000); t1 = now_us();
    bench("local_getset(100M)", t1-t0, r2);
    
    t0 = now_us(); int64_t r3 = global_getset(10000000); t1 = now_us();
    bench("global_getset(10M)", t1-t0, r3);
    
    t0 = now_us(); int64_t r4 = mixed_local_global(10000000); t1 = now_us();
    bench("mixed_local_global(10M)", t1-t0, r4);
    
    t0 = now_us(); int64_t r5 = local_tee_pattern(100000000); t1 = now_us();
    bench("local_tee(100M)", t1-t0, r5);
    
    t0 = now_us(); int64_t r6 = many_params(10000000, 1,2,3,4,5,6,7,8,9,10); t1 = now_us();
    bench("many_params(10M)", t1-t0, r6);
    
    proc_exit(0);
}
