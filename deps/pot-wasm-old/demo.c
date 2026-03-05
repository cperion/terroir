// A small but real program: base64 encoder
// Compiled to WASM, run natively via POT

static const char b64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// Memory layout:
//   0x0000 - 0x003F: b64 table (64 bytes)
//   0x0100 - ...:    input buffer
//   0x1000 - ...:    output buffer

void init_table(void) {
    char *mem = (char *)0;
    for (int i = 0; i < 64; i++)
        mem[i] = b64[i];
}

int base64_encode(int in_ptr, int in_len, int out_ptr) {
    unsigned char *in  = (unsigned char *)in_ptr;
    char          *out = (char *)out_ptr;
    char          *tbl = (char *)0;
    int o = 0;
    int i = 0;

    while (i + 2 < in_len) {
        unsigned int n = ((unsigned int)in[i] << 16)
                       | ((unsigned int)in[i+1] << 8)
                       | ((unsigned int)in[i+2]);
        out[o++] = tbl[(n >> 18) & 0x3F];
        out[o++] = tbl[(n >> 12) & 0x3F];
        out[o++] = tbl[(n >>  6) & 0x3F];
        out[o++] = tbl[(n      ) & 0x3F];
        i += 3;
    }

    if (i < in_len) {
        unsigned int n = (unsigned int)in[i] << 16;
        if (i + 1 < in_len)
            n |= (unsigned int)in[i+1] << 8;
        out[o++] = tbl[(n >> 18) & 0x3F];
        out[o++] = tbl[(n >> 12) & 0x3F];
        if (i + 1 < in_len)
            out[o++] = tbl[(n >> 6) & 0x3F];
        else
            out[o++] = '=';
        out[o++] = '=';
    }

    out[o] = 0;
    return o;
}

// Fibonacci
int fib(int n) {
    if (n <= 1) return n;
    int a = 0, b = 1;
    for (int i = 2; i <= n; i++) {
        int t = a + b;
        a = b;
        b = t;
    }
    return b;
}

// SHA-256 constants (first 8 for demo)
static const unsigned int K[8] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
};

unsigned int rotr(unsigned int x, int n) {
    return (x >> n) | (x << (32 - n));
}

// A single SHA-256 compression round (to show bitwise ops work)
unsigned int sha256_ch(unsigned int e, unsigned int f, unsigned int g) {
    return (e & f) ^ (~e & g);
}

unsigned int sha256_maj(unsigned int a, unsigned int b, unsigned int c) {
    return (a & b) ^ (a & c) ^ (b & c);
}

unsigned int sha256_sigma0(unsigned int a) {
    return rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
}

unsigned int sha256_sigma1(unsigned int e) {
    return rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
}
