// Hello World for POT WASM runner
// Compile: clang --target=wasm32 -O2 -nostdlib -Wl,--no-entry -Wl,--export=_start -Wl,--allow-undefined -o hello.wasm hello.c

typedef unsigned int uint32_t;
typedef long long int64_t;

// WASI imports
__attribute__((import_module("wasi_snapshot_preview1"), import_name("fd_write")))
int fd_write(int fd, const void *iovs, int iovs_len, int *nwritten);

__attribute__((import_module("wasi_snapshot_preview1"), import_name("proc_exit")))
void proc_exit(int code);

__attribute__((import_module("wasi_snapshot_preview1"), import_name("args_sizes_get")))
int args_sizes_get(int *argc, int *argv_buf_size);

__attribute__((import_module("wasi_snapshot_preview1"), import_name("args_get")))
int args_get(int *argv, char *argv_buf);

// iovec struct for WASI
typedef struct { const unsigned char *buf; unsigned int buf_len; } ciovec_t;

static int strlen(const char *s) {
    int n = 0;
    while (s[n]) n++;
    return n;
}

static void print(const char *s) {
    ciovec_t iov;
    iov.buf = (const unsigned char *)s;
    iov.buf_len = strlen(s);
    int nw;
    fd_write(1, &iov, 1, &nw);
}

static void print_num(int n) {
    char buf[12];
    int i = 11;
    buf[i] = 0;
    int neg = 0;
    if (n < 0) { neg = 1; n = -n; }
    if (n == 0) { buf[--i] = '0'; }
    while (n > 0) { buf[--i] = '0' + (n % 10); n /= 10; }
    if (neg) buf[--i] = '-';
    print(&buf[i]);
}

static int fib(int n) {
    if (n <= 1) return n;
    int a = 0, b = 1;
    for (int i = 2; i <= n; i++) {
        int t = a + b;
        a = b;
        b = t;
    }
    return b;
}

void _start(void) {
    print("=== POT WASM Runner ===\n\n");

    // Show args
    int argc, argv_buf_size;
    args_sizes_get(&argc, &argv_buf_size);

    print("argc = ");
    print_num(argc);
    print("\n");

    // Read args if any
    if (argc > 0 && argv_buf_size > 0) {
        int argv[32];
        char argv_buf[1024];
        args_get(argv, argv_buf);
        for (int i = 0; i < argc && i < 32; i++) {
            print("  argv[");
            print_num(i);
            print("] = ");
            print((char *)(long)argv[i]);
            print("\n");
        }
    }

    // Fibonacci
    print("\nFibonacci:\n");
    for (int n = 0; n <= 10; n++) {
        print("  fib(");
        print_num(n);
        print(") = ");
        print_num(fib(n));
        print("\n");
    }

    proc_exit(0);
}
