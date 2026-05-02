# Audit: `increaseDebt` debt-dilution fix on `dev`

**TL;DR — The PR is defensive only. The bug it fixes is *formally unreachable* in current `dev` code via any sequence of valid protocol operations. Apply the PR anyway for parity with `main`, defense-in-depth, and regression resistance — but it is not preventing a currently-exploitable hole.**

---

## The question

A pending PR on `dev` reapplies a fix in `Lender.sol::increaseDebt` (free-debt branch) that handles the edge case `totalFreeDebt == 0 ∧ totalFreeDebtShares > 0`. The same fix already exists on `main` (PR #34, commit `952e3c5`). Two questions:

1. **Is the bug actually exploitable in current `dev` code?** (i.e. can an attacker reach `D=0, S>0` through valid operations?)
2. **Is the fix necessary?**

## What we did

A four-step audit, escalating in rigor as each step couldn't fully close the question.

### Step 1 — Pattern-matching audit (`Nemesis auditor`)

Ran the Nemesis auditor over the **pre-PR** Solidity to find paths to the buggy state.

- Found a **historical exploit** — an old `redeem()` (commit `97fedc2`'s parent) directly mutated `totalFreeDebt` without burning shares. Test `testBorrowUnbacked` from that commit proved the bug.
- The current `redeem()` uses `decreaseDebt()` (which keeps shares + debt in sync) and has a `minDebt` post-check that blocks the original exploit pattern.
- We could not construct a current-code exploit. But "couldn't find one" ≠ "doesn't exist."

### Step 2 — Concrete PoC test

Wrote `test/Lender.t.sol::test_NEMESIS_PoC_zeroDebtNonZeroShares_unbacked_borrow` to demonstrate the exploit *if* the buggy state could be reached. The test uses `vm.store` to construct `D=0, S>0` directly, then exercises the buggy `increaseDebt` branch:

```
With pre-PR code: user2 borrows 50,000 coins, owes only 16,666 — steals 33,333.
With fix:         user2 borrows 50,000 coins, owes 50,000.
```

**Result:** confirms the bug is exploitable *if* the state is reachable, but says nothing about reachability. (Test still on `dev`'s working tree on the PR branch — see Reproduction below.)

### Step 3 — Foundry invariant fuzzing

Wrote `test/LenderInvariant.t.sol` with three Foundry invariants:
- `invariant_freeDebtSharesConsistency` — `D=0 ⇔ S=0`
- `invariant_paidDebtSharesConsistency` — same for paid debt
- `invariant_freeDebtGteShares` — `D ≥ S`

Ran 256 runs × 500 random calls = **128 000 random sequences** of `adjust`/`redeem`/`liquidate`/`writeOff`/`setRedemption`/price moves. **No invariant violations.**

This is strong empirical evidence but still only sampling — fuzzers can miss things SMT solvers don't.

### Step 4 — Formal verification (Z3)

Modeled every state-mutating operation as Z3 SMT constraints and proved the property *inductively*. Two invariants:

| | Definition |
|---|---|
| `I` | `totalFreeDebt = 0  ⇒  totalFreeDebtShares = 0` |
| `J` | `totalFreeDebt ≥ totalFreeDebtShares`  (stronger; implies `I`) |

For each mutator, asked Z3: "Assume the invariant holds in some symbolic prior state; run the operation; does the invariant still hold?"

**Results (`audit/z3-proof-output.txt`):**

| Operation | Preserves `I`? | Preserves `J`? |
|---|---|---|
| `increaseDebt` (pre-PR) | ✓ proven | ✓ proven |
| `increaseDebt` (fixed) | ✓ proven | — |
| `decreaseDebt` non-max | ✓ proven | ✓ proven |
| `decreaseDebt` max | ✗ counter-example* | **✓ proven** |
| `writeOff` redistribute | ✓ proven | ✓ proven |

\* The counter-example for "`decreaseDebt` max preserves I" is `D=1, S=2, X=1` — but this requires `D < S` as a *pre-state*, which violates `J`.

**The inductive chain:**

```
Initial state of a freshly-deployed Lender:  D = 0, S = 0
  ⇒  J holds  (D ≥ S trivially)

Every operation preserves J  (proved by Z3)
  ⇒  J holds in every reachable state

J implies I:
  if D = 0, then S ≤ D = 0, so S = 0

  ⇒  I holds in every reachable state
  ⇒  D < S is NEVER reachable
  ⇒  the precondition of the Part-1 counter-example is unreachable
  ⇒  the bug state (D=0, S>0) is FORMALLY UNREACHABLE
```

### Step 5 — Meta-audit of the formal model

The proof is only as good as the model. Re-ran Nemesis methodology on `formal_verify.py` itself, with `Lender.sol` as ground truth.

- **`mul_div_up` / `mul_div_down`** — wrote `audit/sanity_check_muldiv.py` and got Z3 to formally prove our Python implementation ≡ Solmate's algebraic form for **all** non-negative inputs with `denom > 0` (`unsat` on inequality).
- **All 5 FREE-D/S write sites** in `Lender.sol` (lines 403, 557, 558, 596, 597) are covered by 3 modeled operations.
- **All Z3 preconditions** (`amount ≤ user_debt`, `X ≤ S`, `shares ≤ X`, `D > 0`, `S > 0`, `totalDebt > 0`) are justified by Solidity callers / sum invariants / runtime underflow reverts.
- **Underflow clamps** are textually equivalent.
- **Solidity 0.8 overflow ↔ Z3 unbounded Int**: sound over-approximation (Solidity reverts → no state change → invariant trivially preserved; Z3 considers a superset of reachable states).

Three findings, all informational, none invalidate the verdict — see `META_AUDIT.md` for details.

## Final verdict

**The bug `D=0, S>0` is formally unreachable in current `dev` code.** The PR fix is *not* preventing a currently exploitable bug. Apply it anyway because:

1. **Parity with `main`** — same fix already in `main` (PR #34); without re-applying, dev diverges.
2. **Defense in depth** — `decreaseDebt`'s underflow-protection clamps (`<= ? 0 :`) are themselves defensive, betting that the buggy state *could* occur. The `increaseDebt` fix completes that defense.
3. **Regression resistance** — this fix has been accidentally lost twice already (97fedc2 → lost → 952e3c5 → lost → current PR). A future refactor that re-introduces direct mutation of `totalFreeDebt` (as the OLD `redeem` did, which *was* exploitable) would re-open the hole; this fix limits blast radius.
4. **Negligible cost** — one extra branch on the rare `D=0` path.

## Caveats

- **Scope:** The Z3 proof is for FREE debt only. PAID debt has the same code pattern and is symmetric — the same proof applies (with `accrueInterest` as an additional D-only mutator, behaving like `writeOff redistribute`). Out of scope here because the PR only touches FREE.
- **The proof depends on `redeem` using `decreaseDebt`.** It *currently* does. A future refactor that re-introduces direct `totalFreeDebt -= amountIn` (the historical exploit pattern) would invalidate the proof. The PR fix is a hedge against exactly that.
- **The proof is for Lender-internal logic.** It does not say anything about the broader protocol, oracle attacks, malicious collateral tokens, or governance pathologies.

## Reproduction

### Prereqs
```bash
# Foundry (already on most dev machines)
foundryup

# Z3 SMT solver (Python bindings)
pipx install z3-solver
```

### Switch to the audit branch
```bash
git checkout audit/formal-verify-debt-invariant
```
(Branched from `dev` HEAD `ac6a813` — pre-PR / vulnerable form. The buggy code is intentionally still in `src/Lender.sol` on this branch so the proofs run against the actual vulnerable code path.)

### Run the formal proof (~10 seconds)
```bash
~/.local/pipx/venvs/z3-solver/bin/python3 audit/formal_verify.py
```
Should print 9 `✓ PROVEN INDUCTIVE` and 1 counter-example (the unreachable one).

### Run the mulDivUp/Down equivalence proof
```bash
~/.local/pipx/venvs/z3-solver/bin/python3 audit/sanity_check_muldiv.py
```
Should print all concrete cases passing + `✓ PROVEN EQUIVALENT for all non-neg x, y, denom > 0`.

### Run the Foundry invariant tests
```bash
forge test --match-contract LenderInvariantTest
```
All three invariants pass (256 runs × 500 calls each).

### Run the concrete PoC (with vs without fix)
```bash
# without fix (default on this branch)
forge test --match-test test_NEMESIS_PoC_zeroDebtNonZeroShares_unbacked_borrow

# the test FAILS with the buggy code (user2 steals ~33%);
# apply the fix to src/Lender.sol::increaseDebt and re-run — it passes.
```

## Files in this directory

| File | Purpose |
|---|---|
| `README.md` | this document |
| `VERDICT.md` | original verdict from the formal verification step |
| `META_AUDIT.md` | Nemesis-style meta-audit of the formal model itself |
| `formal_verify.py` | Z3 inductive proof script |
| `sanity_check_muldiv.py` | SMT-proves Z3's `mul_div_up`/`mul_div_down` ≡ Solmate's |
| `z3-proof-output.txt` | output of the formal verification run |

## Methodology summary

```
question
  │
  ▼
[Nemesis pattern audit]  → no current-code path; historical bug only
  │
  ▼
[concrete PoC]           → confirms bug if state reached, says nothing about reachability
  │
  ▼
[Foundry invariant fuzz] → 128k random sequences, no violation (still only sampling)
  │
  ▼
[Z3 inductive proof]     → formally proves D ≥ S is invariant ⇒ D=0,S>0 unreachable
  │
  ▼
[meta-audit of model]    → Z3 mul_div_up/down ≡ Solmate (SMT-proven), all mutators covered
  │
  ▼
verdict
```

Each step strictly stronger than the last. The formal proof would not have been worth the effort if pattern-matching had found a current-code bug; the meta-audit would not have been worth it if the formal proof had given a counter-example. The escalation pattern is reusable for similar audits.
