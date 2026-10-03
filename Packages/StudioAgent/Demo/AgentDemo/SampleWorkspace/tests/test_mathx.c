#include "mathx.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static int near(double a, double b) { return fabs(a - b) < 1e-9; }

int main(void)
{
    int a[] = {1, 2, 3, 4};
    int neg[] = {-3, -4};
    assert(near(mathx_mean(a, 4), 2.5));
    assert(near(mathx_mean(neg, 2), -3.5));
    assert(mathx_clamp(12, 0, 10) == 10);
    assert(mathx_gcd(-12, 18) == 6);
    assert(near(mathx_median(a, 4), 2.5));
    puts("all tests passed");
    return 0;
}
