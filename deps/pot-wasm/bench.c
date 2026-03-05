// Benchmark workloads compiled to WASM

// Recursive fibonacci - classic compute benchmark
int fib_rec(int n) {
    if (n <= 1) return n;
    return fib_rec(n - 1) + fib_rec(n - 2);
}

// Iterative fibonacci
int fib_iter(int n) {
    if (n <= 1) return n;
    int a = 0, b = 1;
    for (int i = 2; i <= n; i++) {
        int t = a + b;
        a = b;
        b = t;
    }
    return b;
}

// SHA-256 compression round (pure compute, no memory)
static unsigned int rotr(unsigned int x, int n) {
    return (x >> n) | (x << (32 - n));
}

unsigned int sha256_rounds(int n) {
    unsigned int a = 0x6a09e667;
    unsigned int b = 0xbb67ae85;
    unsigned int c = 0x3c6ef372;
    unsigned int d = 0xa54ff53a;
    unsigned int e = 0x510e527f;
    unsigned int f = 0x9b05688c;
    unsigned int g = 0x1f83d9ab;
    unsigned int h = 0x5be0cd19;
    unsigned int w = 0x12345678;

    for (int i = 0; i < n; i++) {
        unsigned int S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        unsigned int ch = (e & f) ^ (~e & g);
        unsigned int temp1 = h + S1 + ch + 0x428a2f98 + w;
        unsigned int S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        unsigned int maj = (a & b) ^ (a & c) ^ (b & c);
        unsigned int temp2 = S0 + maj;

        h = g; g = f; f = e; e = d + temp1;
        d = c; c = b; b = a; a = temp1 + temp2;
        w = w ^ a;
    }
    return a;
}

// Sum of array (linear memory access)
int sum_array(int ptr, int len) {
    int *arr = (int *)ptr;
    int total = 0;
    for (int i = 0; i < len; i++)
        total += arr[i];
    return total;
}
