# Halmos Symbolic Execution Results

**Goal:** Cross-validate the Z3 inductive proof using Halmos symbolic execution against an extracted minimal harness.

## Setup

Two contracts, byte-for-byte extracts of the FREE-debt logic from `src/Lender.sol`:

- `src/MockLenderFreeDebt.sol` — pre-PR (vulnerable) form.
- `src/MockLenderFreeDebtFixed.sol` — PR-fixed form.

Each function is annotated with the exact source-line range from `Lender.sol` it was copied from. The only omitted code is:
- The else (paid-debt) branches — separate storage, not under audit.
- The `actualDebtIncrease ≤ maxAllowedDebtIncrease` `require` in `increaseDebt` — failed `require` reverts, doesn't change state, so omitting it gives a sound over-approximation for invariant proof.
- The `collateralBalance`/`safeTransfer` in `writeOff` — no FREE-debt effect.

Halmos `check_*` functions in `test/MockLenderHalmos.t.sol`. Each one:
1. Treats `D, S, X, amount` as symbolic uint256s (via function parameters).
2. Bounds each to `< 2^16` to keep symbolic multiplication tractable.
3. Constrains the pre-state with the invariant pre-condition (`D > 0 ∨ S = 0` for `I`, or `D ≥ S` for `J`) plus `X ≤ S` (sum invariant).
4. Installs the symbolic state via `vm.store` at the storage slots verified by `forge inspect`.
5. Runs ONE operation.
6. Asserts the post-state still satisfies the invariant.

## Results vs Z3

| Test | Halmos | Z3 |
|---|---|---|
| `check_I_after_increaseDebt` | ✅ **PASS** (0.07s) | ✅ proven |
| `check_I_after_decreaseDebt_nonmax` | ⏱ TIMEOUT (120s) | ✅ proven |
| `check_I_after_decreaseDebt_max` | ❌ counter-example | ❌ same CE |
| `check_I_after_writeOffRedistribute` | ✅ **PASS** (0.06s) | ✅ proven |
| `check_J_after_increaseDebt` | ⏱ TIMEOUT (120s) | ✅ proven |
| `check_J_after_decreaseDebt_nonmax` | ⏱ TIMEOUT (120s) | ✅ proven |
| `check_J_after_decreaseDebt_max` | ⏱ TIMEOUT (120s) | ✅ proven |
| `check_J_after_writeOffRedistribute` | ✅ **PASS** (0.04s) | ✅ proven |

## The counter-example

Halmos counter-example for `check_I_after_decreaseDebt_max`:

```
D = 0x8000   (32768   = 2^15)
S = 0xc000   (49152   = 3·2^14)
X = 0xbfff   (49151   = S - 1)
```

Same shape as Z3's counter-example (`D=1, S=2, X=1` — `D < S`, `X = S − 1`). The exploit math:

```
amount  = ceil(X · D / S)   = ceil(49151 · 32768 / 49152)   = D = 32768
new_D   = max(0, D - amount) = 0           ← clamps
new_S   = max(0, S - X)      = 1           ← does NOT clamp
                                            ↳ buggy state D=0, S>0
```

But this CE requires `D < S` as a pre-state. Z3 proved `J: D ≥ S` is inductive across every operation, so `D < S` is never reachable from the initial state `(D=0, S=0)`. Halmos timed out on the same J-preservation proofs but did not produce any counter-example for them either — meaning Halmos cannot refute, only fail to confirm.

## Where Halmos and Z3 agree

**Three operations proven safe by both tools:**
- `increaseDebt` preserves `I`
- `writeOffRedistribute` preserves `I`
- `writeOffRedistribute` preserves `J`

**Same counter-example for I (decreaseDebt max from D < S pre-state).**

## Where they diverge

Halmos times out on every query that involves symbolic `mulDivUp` / `mulDivDown` with two symbolic operands. This is a known SMT limitation — symbolic uint256 multiplication explodes the bit-blasted formula. Z3 with unbounded `Int` arithmetic solves these in milliseconds because it doesn't bit-blast.

The 4 timeouts:
- `check_I_after_decreaseDebt_nonmax` — `shares = floor(amount * S / D)` with both `amount` and `S` symbolic
- `check_J_after_decreaseDebt_nonmax` — same
- `check_J_after_decreaseDebt_max` — `amount = ceil(X * D / S)` with both `X` and `D` symbolic
- `check_J_after_increaseDebt` — `shares = ceil(amount * S / D)` with both `amount` and `S` symbolic

Reducing `CAP` from `2^32` to `2^16` did not help — yices struggles regardless of bit-width once you have symbolic multiplication of two arbitrary-precision values.

## Verdict

**Halmos cross-validates the Z3 result on every query it can solve.** No divergence between the two tools. The counter-example is identical in shape. The Halmos timeouts do not represent a Halmos finding bugs that Z3 missed — they represent SMT bit-blasting failing on hard arithmetic, which Z3 sidesteps by using unbounded integers.

**Combined verdict (Z3 + Halmos):**
- The bug `D=0, S>0` is reachable IF `D < S` pre-state is reachable.
- Z3 (and Halmos for the operations it can solve) proves `D ≥ S` is preserved by every operation.
- Initial state has `D = S = 0`, satisfying `D ≥ S`.
- Therefore `D < S` is never reachable.
- Therefore the bug state is **formally unreachable**.

## Reproduction

```bash
# Halmos profile (forces no-via-ir + ast)
rm -rf out
FOUNDRY_PROFILE=halmos forge build

# Run halmos
FOUNDRY_PROFILE=halmos halmos --contract MockLenderHalmosTest --solver-timeout-assertion 120000
```

Expect: 3 PASS, 1 FAIL (with the counter-example shown above), 4 TIMEOUT.

## Why we still need Z3

Halmos times out on the most important query: `check_J_after_decreaseDebt_max` — the one that proves the counter-example precondition is unreachable. Without that piece, you have:

> "decreaseDebt max can produce D=0, S>0 from a D<S pre-state — but we don't know if that pre-state is reachable."

That's a "we couldn't refute the bug" verdict, not a "the bug is unreachable" verdict. Z3 closes the gap because integer arithmetic doesn't bit-blast.

## Artifacts

- `src/MockLenderFreeDebt.sol` — extracted harness (pre-PR form)
- `src/MockLenderFreeDebtFixed.sol` — extracted harness (FIX form)
- `test/MockLenderHalmos.t.sol` — Halmos `check_*` functions
- `test/MockLenderHalmosFixed.t.sol` — same for FIX form (not yet executed)
- `audit/halmos-output.txt` — full halmos run output
- `audit/halmos-summary.txt` — filtered to PASS/FAIL/TIMEOUT lines + CE
