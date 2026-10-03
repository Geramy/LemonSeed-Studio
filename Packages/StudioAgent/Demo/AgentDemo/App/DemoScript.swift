import StudioAgent

/// The offline demo: a believable run of the agent fixing `mathx_mean`,
/// replayed by `ScriptedLLMClient`. The engine pill says "Scripted demo" so
/// it is never mistaken for a live model.
enum DemoScript {
    static let replies: [ScriptedLLMClient.Reply] = [
        .toolCalls([("grep", ["pattern": "mathx_mean", "path": "src"]), ("read", ["path": "src/mathx.c", "offset": 1, "limit": 16])],
                   reasoning: "The user reports mean() is wrong for negative numbers. I should look at how the sum is divided: "
                       + "a long divided by a size_t converts the sum to unsigned, and integer division would also drop the fraction."),
        .toolCalls([("edit", ["path": "src/mathx.c", "edits": [["oldText": "    return sum / n;", "newText": "    return (double)sum / (double)n;"]]])],
                   text: "`sum / n` divides a `long` by a `size_t`: the sum is converted to unsigned (so negative sums wrap) "
                       + "and the division truncates. I'll divide as `double`."),
        .toolCalls([("bash", ["command": "grep -n 'mathx_mean' tests/test_mathx.c"])]),
        .text("""
        Fixed `mathx_mean` in `src/mathx.c`.

        **Cause.** `sum / n` mixed a signed `long` with an unsigned `size_t`, so the sum was converted to unsigned — \
        a negative total wrapped to a huge number — and the integer division dropped the fractional part.

        **Fix.** Divide in floating point:

        ```c
        return (double)sum / (double)n;
        ```

        The existing tests cover both cases (`{1, 2, 3, 4}` → 2.5 and `{-3, -4}` → −3.5).
        """, reasoning: "Tests at lines 13-14 already exercise both failure modes."),
    ]

    static let explanation = ScriptedLLMClient.Reply.text("""
    `mathx_mean` returns the arithmetic mean of `n` integers.

    1. It returns `0.0` for an empty array instead of dividing by zero.
    2. It accumulates into a `long`, which avoids overflow for typical inputs.
    3. **Watch out:** `return sum / n;` divides a signed `long` by an unsigned `size_t`. The sum is converted to \
    unsigned first, so negative totals wrap around, and the division is integral, so `{1, 2}` gives `1`, not `1.5`.

    Casting both operands to `double` fixes both problems.
    """)
}
