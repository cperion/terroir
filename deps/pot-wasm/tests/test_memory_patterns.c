// Memory access pattern tests
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

#define SIZE (1024 * 1024)  // 1M elements = 4MB
static int arr[SIZE];

// Sequential read
__attribute__((noinline))
static int64_t seq_read(int iters) {
    int64_t sum = 0;
    for (int iter = 0; iter < iters; iter++) {
        for (int i = 0; i < SIZE; i++) {
            sum += arr[i];
        }
    }
    return sum;
}

// Sequential write
__attribute__((noinline))
static int64_t seq_write(int iters) {
    for (int iter = 0; iter < iters; iter++) {
        for (int i = 0; i < SIZE; i++) {
            arr[i] = i * 7;
        }
    }
    return arr[0];
}

// Strided access (every 16th element)
__attribute__((noinline))
static int64_t stride_read(int iters) {
    int64_t sum = 0;
    for (int iter = 0; iter < iters; iter++) {
        for (int i = 0; i < SIZE; i += 16) {
            sum += arr[i];
        }
    }
    return sum;
}

// Reverse sequential
__attribute__((noinline))
static int64_t reverse_read(int iters) {
    int64_t sum = 0;
    for (int iter = 0; iter < iters; iter++) {
        for (int i = SIZE - 1; i >= 0; i--) {
            sum += arr[i];
        }
    }
    return sum;
}

// 2D row-major traversal
#define MAT_SIZE 1024
static int mat[MAT_SIZE * MAT_SIZE];

__attribute__((noinline))
static int64_t row_major(int iters) {
    int64_t sum = 0;
    for (int iter = 0; iter < iters; iter++) {
        for (int i = 0; i < MAT_SIZE; i++) {
            for (int j = 0; j < MAT_SIZE; j++) {
                sum += mat[i * MAT_SIZE + j];
            }
        }
    }
    return sum;
}

// 2D column-major traversal (cache-unfriendly)
__attribute__((noinline))
static int64_t col_major(int iters) {
    int64_t sum = 0;
    for (int iter = 0; iter < iters; iter++) {
        for (int j = 0; j < MAT_SIZE; j++) {
            for (int i = 0; i < MAT_SIZE; i++) {
                sum += mat[i * MAT_SIZE + j];
            }
        }
    }
    return sum;
}

// Init arrays
static void init_arrays(void) {
    for (int i = 0; i < SIZE; i++) arr[i] = i;
    for (int i = 0; i < MAT_SIZE * MAT_SIZE; i++) mat[i] = i & 0xFF;
}

void _start(void) {
    int64_t t0, t1;
    
    print("Memory Pattern Benchmark\n");
    print("========================\n\n");
    
    init_arrays();
    
    t0 = now_us(); int64_t r1 = seq_read(10); t1 = now_us();
    bench("seq_read(4MB x10)", t1-t0, r1);
    
    t0 = now_us(); int64_t r2 = seq_write(10); t1 = now_us();
    bench("seq_write(4MB x10)", t1-t0, r2);
    
    t0 = now_us(); int64_t r3 = stride_read(10); t1 = now_us();
    bench("stride_read(256KB x10)", t1-t0, r3);
    
    t0 = now_us(); int64_t r4 = reverse_read(10); t1 = now_us();
    bench("reverse_read(4MB x10)", t1-t0, r4);
    
    t0 = now_us(); int64_t r5 = row_major(5); t1 = now_us();
    bench("row_major(4MB x5)", t1-t0, r5);
    
    t0 = now_us(); int64_t r6 = col_major(5); t1 = now_us();
    bench("col_major(4MB x5)", t1-t0, r6);
    
    proc_exit(0);
}
