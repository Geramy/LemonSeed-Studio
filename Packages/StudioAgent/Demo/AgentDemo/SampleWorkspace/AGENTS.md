# mathx

A tiny C99 statistics library used to demo the LemonSeed agent.

- Sources are in `src/`, tests in `tests/` (one `test_*.c` per module).
- Style: 4-space indentation, K&R braces, `snake_case`, no global state.
- Every public function is declared in `src/mathx.h` with a one-line comment.
- Prefer `double` for results; never divide integers when a fraction is expected.
