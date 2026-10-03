# Kernel Lab

Write GPU kernels on an iPad and run them on a **desktop GPU** over Thunderbolt.

## Quick start

1. Open `kernels/saxpy.cl`.
2. Press **⌘R** to build and run.
3. Inspect the output buffer as a table or *heat map*.

```cpp
__kernel void saxpy(float a, __global const float* x, __global float* y) {
    const size_t i = get_global_id(0);
    y[i] = a * x[i] + y[i];
}
```

> Kernels run in a separate sandbox session, so a fault never takes the engine down.

| Target   | ISA      | Wave |
|----------|----------|------|
| R9700    | gfx1201  | 32   |

See the [plan](../planning/PLAN.md) for details.
