#include "mathx.h"

#include <stdlib.h>
#include <string.h>

double mathx_mean(const int *values, size_t n)
{
    if (n == 0) {
        return 0.0;
    }
    long sum = 0;
    for (size_t i = 0; i < n; i++) {
        sum += values[i];
    }
    return sum / n;
}

int mathx_clamp(int value, int lo, int hi)
{
    if (value < lo) {
        return lo;
    }
    if (value > hi) {
        return hi;
    }
    return value;
}

int mathx_gcd(int a, int b)
{
    while (b != 0) {
        int t = a % b;
        a = b;
        b = t;
    }
    return a < 0 ? -a : a;
}

static int compare_ints(const void *a, const void *b)
{
    int x = *(const int *)a;
    int y = *(const int *)b;
    return (x > y) - (x < y);
}

double mathx_median(const int *values, size_t n)
{
    if (n == 0) {
        return 0.0;
    }
    int *copy = malloc(n * sizeof *copy);
    memcpy(copy, values, n * sizeof *copy);
    qsort(copy, n, sizeof *copy, compare_ints);
    double m = n % 2 ? copy[n / 2] : (copy[n / 2 - 1] + copy[n / 2]) / 2.0;
    free(copy);
    return m;
}
