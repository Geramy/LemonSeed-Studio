#ifndef MATHX_H
#define MATHX_H

#include <stddef.h>

/* Arithmetic mean of n values; 0 when n is 0. */
double mathx_mean(const int *values, size_t n);

/* value limited to the range [lo, hi]. */
int mathx_clamp(int value, int lo, int hi);

/* Greatest common divisor of a and b (always non-negative). */
int mathx_gcd(int a, int b);

/* Median of n values (sorts a copy); 0 when n is 0. */
double mathx_median(const int *values, size_t n);

#endif
