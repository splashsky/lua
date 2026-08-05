# tools — verification harnesses

Correctness tools that are too large or too slow to live in the unit-test suite, but
which back specific claims made in commit messages.

## `strtod_verify/`

Checks the Eisel–Lemire float-parsing fast path against our own big-decimal parser,
which is the strongest oracle available: the slow path is the one that has always been
correctly rounded, and Eisel–Lemire is only ever allowed to *bypass* it, never replace
it. The harness parses a large corpus both ways and asserts the resulting bit patterns
and consumed lengths are identical.

The corpus is deliberately weighted toward the cases that break naive implementations:

- random doubles round-tripped through `%.17g` across the whole exponent range
- digit strings of every length up to 25, crossed with the full decimal exponent range
- **neighbours of random doubles**, which land on rounding boundaries where the 128-bit
  approximation must decline rather than guess
- subnormals and the extremes of the exponent range

Run it from the repository root:

```powershell
odin run tools/strtod_verify -collection:lang=src -o:speed
```

It reports how many cases it checked in each category and fails loudly on any mismatch.

## `strtod_diff.lua`

The same shape of corpus, but emitted as text so the output of two *interpreters* can be
compared. Run it under our `lua` and under a reference build and diff the results:

```powershell
lua tools/strtod_diff.lua > ours.txt
reflua tools/strtod_diff.lua > ref.txt
```

Values are printed as raw IEEE bit patterns rather than decimal text, so a one-ulp
difference cannot hide behind rounding in the printing.
