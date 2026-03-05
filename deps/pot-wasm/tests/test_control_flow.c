// Control flow stress test
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

// Dense switch (br_table)
__attribute__((noinline))
static int dense_switch(int n, int seed) {
    int sum = 0;
    uint32_t state = seed;
    for (int i = 0; i < n; i++) {
        state = state * 1103515245 + 12345;
        int x = (state >> 8) & 15;
        switch (x) {
            case 0: sum += 1; break;
            case 1: sum += 2; break;
            case 2: sum += 3; break;
            case 3: sum += 4; break;
            case 4: sum += 5; break;
            case 5: sum += 6; break;
            case 6: sum += 7; break;
            case 7: sum += 8; break;
            case 8: sum += 9; break;
            case 9: sum += 10; break;
            case 10: sum += 11; break;
            case 11: sum += 12; break;
            case 12: sum += 13; break;
            case 13: sum += 14; break;
            case 14: sum += 15; break;
            case 15: sum += 16; break;
        }
    }
    return sum;
}

// Sparse switch (if-else chain)
__attribute__((noinline))
static int sparse_switch(int n, int seed) {
    int sum = 0;
    uint32_t state = seed;
    for (int i = 0; i < n; i++) {
        state = state * 1103515245 + 12345;
        int x = (state >> 8) % 100;
        if (x == 0) sum += 1;
        else if (x == 25) sum += 2;
        else if (x == 50) sum += 3;
        else if (x == 75) sum += 4;
        else sum += 0;
    }
    return sum;
}

// Nested loops
__attribute__((noinline))
static int nested_loops(int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            for (int k = 0; k < 10; k++) {
                sum += (i + j + k) & 1;
            }
        }
    }
    return sum;
}

// Loop with break
__attribute__((noinline))
static int loop_break(int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        int found = 0;
        for (int j = 0; j < 100; j++) {
            if ((i + j) % 97 == 0) {
                sum += j;
                found = 1;
                break;
            }
        }
        if (!found) sum += i;
    }
    return sum;
}

// Loop with continue
__attribute__((noinline))
static int loop_continue(int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < 100; j++) {
            if ((i + j) % 3 == 0) continue;
            sum += j;
        }
    }
    return sum;
}

// Deep nested if
__attribute__((noinline))
static int deep_if(int n, int seed) {
    int sum = 0;
    uint32_t state = seed;
    for (int i = 0; i < n; i++) {
        state = state * 1103515245 + 12345;
        int a = (state >> 8) & 1;
        int b = (state >> 9) & 1;
        int c = (state >> 10) & 1;
        int d = (state >> 11) & 1;
        int e = (state >> 12) & 1;
        
        if (a) {
            if (b) {
                if (c) {
                    if (d) {
                        if (e) sum += 1;
                        else sum += 2;
                    } else {
                        if (e) sum += 3;
                        else sum += 4;
                    }
                } else {
                    if (d) {
                        if (e) sum += 5;
                        else sum += 6;
                    } else {
                        if (e) sum += 7;
                        else sum += 8;
                    }
                }
            } else {
                sum += 16;
            }
        } else {
            sum += 32;
        }
    }
    return sum;
}

void _start(void) {
    int64_t t0, t1;
    int seed = 0xDEADBEEF;
    
    print("Control Flow Benchmark\n");
    print("======================\n\n");
    
    t0 = now_us(); int r1 = dense_switch(50000000, seed); t1 = now_us();
    bench("dense_switch(50M)", t1-t0, r1);
    
    t0 = now_us(); int r2 = sparse_switch(50000000, seed); t1 = now_us();
    bench("sparse_switch(50M)", t1-t0, r2);
    
    t0 = now_us(); int r3 = nested_loops(100); t1 = now_us();
    bench("nested_loops(100^3)", t1-t0, r3);
    
    t0 = now_us(); int r4 = loop_break(100000); t1 = now_us();
    bench("loop_break(100K)", t1-t0, r4);
    
    t0 = now_us(); int r5 = loop_continue(10000); t1 = now_us();
    bench("loop_continue(10K)", t1-t0, r5);
    
    t0 = now_us(); int r6 = deep_if(10000000, seed); t1 = now_us();
    bench("deep_if(10M)", t1-t0, r6);
    
    proc_exit(0);
}
