#include <stdio.h>
#include <stdint.h>
#include <time.h>

int fib_rec(int n) {
    if (n <= 1) return n;
    return fib_rec(n - 1) + fib_rec(n - 2);
}

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

static uint32_t rotr(uint32_t x, int n) {
    return (x >> n) | (x << (32 - n));
}

uint32_t sha256_rounds(int n) {
    uint32_t a = 0x6a09e667, b = 0xbb67ae85, c = 0x3c6ef372, d = 0xa54ff53a;
    uint32_t e = 0x510e527f, f = 0x9b05688c, g = 0x1f83d9ab, h = 0x5be0cd19;
    uint32_t w = 0x12345678;

    for (int i = 0; i < n; i++) {
        uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t temp1 = h + S1 + ch + 0x428a2f98 + w;
        uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temp2 = S0 + maj;

        h = g; g = f; f = e; e = d + temp1;
        d = c; c = b; b = a; a = temp1 + temp2;
        w = w ^ a;
    }
    return a;
}

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

int main(void) {
    int N = 10;
    int64_t t0, t1;
    int r;
    uint32_t r32;

    volatile int vr;
    volatile uint32_t vr32;
    volatile int input35 = 35;
    volatile int input1B = 1000000000;
    volatile int input1M = 1000000;

    // Warmup
    vr = fib_rec(input35);
    t0 = now_ns();
    for (int i = 0; i < N; i++) vr = fib_rec(input35);
    t1 = now_ns();
    r = vr;
    printf("fib_rec(35)     = %d  (%ld us)\n", r, (t1 - t0) / N / 1000);

    // SHA-256
    vr32 = sha256_rounds(input1M);
    t0 = now_ns();
    for (int i = 0; i < N; i++) vr32 = sha256_rounds(input1M);
    t1 = now_ns();
    r32 = vr32;
    printf("sha256 1M       = 0x%08X  (%ld us)\n", r32, (t1 - t0) / N / 1000);

    // Iterative fib
    vr = fib_iter(input1B);
    t0 = now_ns();
    for (int i = 0; i < N; i++) vr = fib_iter(input1B);
    t1 = now_ns();
    r = vr;
    printf("fib_iter(1B)    = %d  (%ld us)\n", r, (t1 - t0) / N / 1000);

    return 0;
}
