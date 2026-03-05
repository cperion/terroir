// Comprehensive WASM runtime benchmark
// Tests: compute, memory, branches, function calls, indirect calls

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

__attribute__((noinline))
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
    print(" us");
    if (result) { print("  ("); print_num(result); print(")"); }
    print("\n");
}

// ─── 1. Recursive fib: deep call stack ───

__attribute__((noinline))
static int fib_rec(int n) {
    if (n <= 1) return n;
    return fib_rec(n - 1) + fib_rec(n - 2);
}

// ─── 2. Sieve of Eratosthenes: memory + branches ───

#define SIEVE_SIZE 1000000
static unsigned char sieve[SIEVE_SIZE];

__attribute__((noinline))
static int count_primes(int limit) {
    for (int i = 0; i < limit; i++) sieve[i] = 1;
    sieve[0] = sieve[1] = 0;
    for (int i = 2; i * i < limit; i++) {
        if (sieve[i]) {
            for (int j = i * i; j < limit; j += i)
                sieve[j] = 0;
        }
    }
    int count = 0;
    for (int i = 0; i < limit; i++) count += sieve[i];
    return count;
}

// ─── 3. Matrix multiply: nested loops + memory ───

#define MAT_N 128
static int mat_a[MAT_N * MAT_N];
static int mat_b[MAT_N * MAT_N];
static int mat_c[MAT_N * MAT_N];

__attribute__((noinline))
static int matrix_mul(int n) {
    // Init
    for (int i = 0; i < n * n; i++) {
        mat_a[i] = i & 0xFF;
        mat_b[i] = (i * 7 + 3) & 0xFF;
        mat_c[i] = 0;
    }
    // Multiply
    for (int i = 0; i < n; i++)
        for (int k = 0; k < n; k++) {
            int a_ik = mat_a[i * n + k];
            for (int j = 0; j < n; j++)
                mat_c[i * n + j] += a_ik * mat_b[k * n + j];
        }
    // Checksum
    int sum = 0;
    for (int i = 0; i < n * n; i++) sum += mat_c[i];
    return sum;
}

// ─── 4. Quicksort: recursion + memory + branches ───

#define SORT_N 10000
static int sort_arr[SORT_N];

static void swap(int *a, int *b) { int t = *a; *a = *b; *b = t; }

static int partition(int *arr, int lo, int hi) {
    int pivot = arr[hi];
    int i = lo;
    for (int j = lo; j < hi; j++) {
        if (arr[j] < pivot) { swap(&arr[i], &arr[j]); i++; }
    }
    swap(&arr[i], &arr[hi]);
    return i;
}

static void quicksort(int *arr, int lo, int hi) {
    if (lo < hi) {
        int p = partition(arr, lo, hi);
        quicksort(arr, lo, p - 1);
        quicksort(arr, p + 1, hi);
    }
}

__attribute__((noinline))
static int do_sort(int n) {
    // LCG init
    uint32_t seed = 12345;
    for (int i = 0; i < n; i++) {
        seed = seed * 1103515245 + 12345;
        sort_arr[i] = (int)(seed >> 8) & 0x7FFFFF;
    }
    quicksort(sort_arr, 0, n - 1);
    // Verify sorted + return checksum
    int sum = sort_arr[0];
    for (int i = 1; i < n; i++) {
        if (sort_arr[i] < sort_arr[i-1]) return -1; // not sorted
        sum ^= sort_arr[i];
    }
    return sum;
}

// ─── 5. SHA-256 full block: bitwise heavy ───

static uint32_t rotr32(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static uint32_t K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

__attribute__((noinline))
static uint32_t sha256_block(int rounds) {
    uint32_t H[8] = {
        0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
        0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
    };

    for (int r = 0; r < rounds; r++) {
        uint32_t W[64];
        // Fake message schedule from round counter
        for (int i = 0; i < 16; i++)
            W[i] = (uint32_t)(r * 16 + i) * 0x01010101;
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = rotr32(W[i-15], 7) ^ rotr32(W[i-15], 18) ^ (W[i-15] >> 3);
            uint32_t s1 = rotr32(W[i-2], 17) ^ rotr32(W[i-2], 19) ^ (W[i-2] >> 10);
            W[i] = W[i-16] + s0 + W[i-7] + s1;
        }

        uint32_t a=H[0],b=H[1],c=H[2],d=H[3],e=H[4],f=H[5],g=H[6],h=H[7];
        for (int i = 0; i < 64; i++) {
            uint32_t S1 = rotr32(e,6) ^ rotr32(e,11) ^ rotr32(e,25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = h + S1 + ch + K[i] + W[i];
            uint32_t S0 = rotr32(a,2) ^ rotr32(a,13) ^ rotr32(a,22);
            uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = S0 + maj;
            h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
        }
        H[0]+=a;H[1]+=b;H[2]+=c;H[3]+=d;H[4]+=e;H[5]+=f;H[6]+=g;H[7]+=h;
    }
    return H[0];
}

// ─── 6. N-body (simplified): floating point ───

typedef struct { double x, y, z, vx, vy, vz, mass; } Body;

#define NBODIES 5
static Body bodies[NBODIES];

static double fabs_d(double x) { return x < 0 ? -x : x; }

__attribute__((noinline))
static double nbody(int steps) {
    // Sun + 4 planets (simplified)
    double PI = 3.141592653589793;
    double SOLAR_MASS = 4 * PI * PI;
    double DAYS_PER_YEAR = 365.24;

    bodies[0] = (Body){0,0,0,0,0,0, SOLAR_MASS};  // Sun
    bodies[1] = (Body){4.84,-1.16,-0.10, 0.001*DAYS_PER_YEAR,0.007*DAYS_PER_YEAR,0.0*DAYS_PER_YEAR, 0.001*SOLAR_MASS};
    bodies[2] = (Body){8.34,4.12,-0.40, -0.003*DAYS_PER_YEAR,0.005*DAYS_PER_YEAR,0.0*DAYS_PER_YEAR, 0.0003*SOLAR_MASS};
    bodies[3] = (Body){12.89,-15.11,-0.22, 0.003*DAYS_PER_YEAR,0.002*DAYS_PER_YEAR,0.0*DAYS_PER_YEAR, 0.00004*SOLAR_MASS};
    bodies[4] = (Body){15.38,-25.92,0.18, 0.003*DAYS_PER_YEAR,0.002*DAYS_PER_YEAR,0.0*DAYS_PER_YEAR, 0.00005*SOLAR_MASS};

    double dt = 0.01;
    for (int s = 0; s < steps; s++) {
        // Update velocities
        for (int i = 0; i < NBODIES; i++) {
            for (int j = i + 1; j < NBODIES; j++) {
                double dx = bodies[i].x - bodies[j].x;
                double dy = bodies[i].y - bodies[j].y;
                double dz = bodies[i].z - bodies[j].z;
                double d2 = dx*dx + dy*dy + dz*dz;
                double mag = dt / (d2 * d2);  // approximate 1/d^3
                // Avoid sqrt for simplicity — just use d^4 as denominator
                bodies[i].vx -= dx * bodies[j].mass * mag;
                bodies[i].vy -= dy * bodies[j].mass * mag;
                bodies[i].vz -= dz * bodies[j].mass * mag;
                bodies[j].vx += dx * bodies[i].mass * mag;
                bodies[j].vy += dy * bodies[i].mass * mag;
                bodies[j].vz += dz * bodies[i].mass * mag;
            }
        }
        // Update positions
        for (int i = 0; i < NBODIES; i++) {
            bodies[i].x += dt * bodies[i].vx;
            bodies[i].y += dt * bodies[i].vy;
            bodies[i].z += dt * bodies[i].vz;
        }
    }
    // Energy
    double e = 0;
    for (int i = 0; i < NBODIES; i++) {
        e += 0.5 * bodies[i].mass * (bodies[i].vx*bodies[i].vx + bodies[i].vy*bodies[i].vy + bodies[i].vz*bodies[i].vz);
    }
    // Return as integer (scaled)
    return e;
}

// ─── Entry ───

void _start(void) {
    int64_t t0, t1;

    print("WASM Runtime Benchmark\n");
    print(  "======================\n\n");

    // 1. Recursive fib
    t0 = now_us(); int r1 = fib_rec(40); t1 = now_us();
    bench("fib_rec(40)", t1-t0, r1);

    // 2. Sieve of Eratosthenes
    t0 = now_us();
    int primes = 0;
    for (int i = 0; i < 10; i++) primes = count_primes(SIEVE_SIZE);
    t1 = now_us();
    bench("sieve(1M) x10", t1-t0, primes);

    // 3. Matrix multiply
    t0 = now_us();
    int msum = 0;
    for (int i = 0; i < 10; i++) msum = matrix_mul(MAT_N);
    t1 = now_us();
    bench("matmul(128x128) x10", t1-t0, msum);

    // 4. Quicksort
    t0 = now_us();
    int ssum = 0;
    for (int i = 0; i < 100; i++) ssum = do_sort(SORT_N);
    t1 = now_us();
    bench("qsort(10K) x100", t1-t0, ssum);

    // 5. SHA-256 full blocks
    t0 = now_us();
    uint32_t h = sha256_block(100000);
    t1 = now_us();
    bench("sha256(100K blocks)", t1-t0, h);

    // 6. N-body
    t0 = now_us();
    double energy = 0;
    for (int i = 0; i < 10; i++) energy = nbody(1000000);
    t1 = now_us();
    bench("nbody(1M steps) x10", t1-t0, (int64_t)(energy * 1000));

    proc_exit(0);
}
