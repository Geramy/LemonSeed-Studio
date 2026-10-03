#include <stdio.h>
#include <stdint.h>
#include <time.h>

// Counts the primes below N with a simple sieve, then prints a few of them.
#define N 2000000

static unsigned char composite[N];

int main(int argc, char **argv) {
    printf("Hello, iPad!\n");
    printf("argv[0] = %s, argc = %d\n", argc > 0 ? argv[0] : "?", argc);

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int count = 0;
    uint64_t sum = 0;
    for (int i = 2; i < N; i++) {
        if (composite[i]) continue;
        count++;
        sum += (uint64_t)i;
        for (int64_t j = (int64_t)i * i; j < N; j += i) composite[j] = 1;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;

    printf("primes below %d: %d (sum %llu)\n", N, count, (unsigned long long)sum);
    printf("sieve took %.1f ms inside the program\n", ms);
    return 0;
}
