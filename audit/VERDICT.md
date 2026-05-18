# Audit Verdict: Free-Debt Invariant in Lender.sol

## Question
Does the PR fix (re-applied in `increaseDebt`) prevent a real, reachable bug in current dev code?

## Method
Formal verification via Z3 SMT solver over unbounded integer arithmetic. We proved (or refuted) that key invariants are **inductive** across every state-mutating operation in Lender.sol.

## Invariants tested

| Invariant | Definition |
|-----------|------------|
| **I** | `totalFreeDebt = 0  ⇒  totalFreeDebtShares = 0` |
| **J** | `totalFreeDebt ≥ totalFreeDebtShares` (stronger; implies I) |

## Operations modeled (the only writers of `totalFreeDebt`/`totalFreeDebtShares`)

1. `increaseDebt` (pre-PR, vulnerable form)
2. `increaseDebt` (PR-fixed form)
3. `decreaseDebt` non-max path
4. `decreaseDebt` max path (`type(uint).max`)
5. `writeOff` redistribute step

## Results

### Invariant I (the property the PR is "fixing")

| Operation | Result |
|-----------|--------|
| increaseDebt PRE-PR | ✓ PROVEN INDUCTIVE |
| increaseDebt FIX | ✓ PROVEN INDUCTIVE |
| decreaseDebt non-max | ✓ PROVEN INDUCTIVE |
| **decreaseDebt max** | ✗ **COUNTER-EXAMPLE** |
| writeOff redistribute | ✓ PROVEN INDUCTIVE |

**Counter-example:** `D=1, S=2, X=1` → `amount=ceil(1·1/2)=1` → clamps:
- `D' = max(0, 1-1) = 0`
- `S' = max(0, 2-1) = 1`
- ⇒ Post-state `D=0, S=1` violates I

⚠️ But this requires the **pre-state to have `D < S`** — which is the deeper question.

### Invariant J — the stronger property that traps the counter-example

| Operation | Result |
|-----------|--------|
| increaseDebt PRE-PR | ✓ PROVEN INDUCTIVE |
| decreaseDebt non-max | ✓ PROVEN INDUCTIVE |
| **decreaseDebt max** | ✓ **PROVEN INDUCTIVE** |
| writeOff redistribute | ✓ PROVEN INDUCTIVE |

**Every operation preserves `D ≥ S`**.

## Inductive argument

```
Initial state of a freshly-deployed Lender:  D = 0, S = 0
  ⇒ J holds (D ≥ S trivially)

Every operation preserves J  (proved by Z3, Part 2)
  ⇒ J holds in every reachable state

J implies I:
  if D = 0, then S ≤ D = 0, so S = 0

  ⇒ I holds in every reachable state
  ⇒ The pre-condition of the Part-1 counter-example (D=1, S=2 — i.e., D < S)
     is UNREACHABLE
  ⇒ The bug (`D = 0  ∧  S > 0`) is FORMALLY UNREACHABLE
```

## Verdict

**The bug the PR fixes is not reachable in current dev code through any sequence of operations.**

The PR is:
- **NOT** required to prevent an exploit reachable today.
- **STILL JUSTIFIED** as defensive coding:
  1. **Parity with `main`** — same fix was merged in PR #34 (`952e3c5`); without re-applying, dev diverges from main.
  2. **Defense-in-depth** — `decreaseDebt`'s underflow-protection clamps already defensively assume the buggy state CAN occur. The `increaseDebt` fix completes that defense.
  3. **Regression resistance** — the proof depends on the redeem function using `decreaseDebt` (it does today). If a future refactor re-introduces direct mutation of `totalFreeDebt` (as the OLD redeem did, and which DID cause this bug historically — see commit `97fedc2`'s test `testBorrowUnbacked`), the fix limits blast radius.
  4. **Cheap insurance** — only one extra branch on the rare `D=0` path; gas cost is negligible.

## Caveats

- **Modeling assumptions:** Z3 model used unbounded integers, matching Solidity 0.8 semantics where overflow reverts.
- **Solver completeness:** Z3 returned UNSAT (proven) for J inductiveness in seconds — high confidence.
- **Historical bug was real:** In code that had the OLD `redeem` directly subtracting `totalFreeDebt -= amountIn` without burning shares, `D < S` (and thus `D=0, S>0`) WAS reachable. Test `testBorrowUnbacked` from commit `97fedc2` proved it. The redeem refactor + minDebt check closed that path.

## Recommendation

**Apply the PR.** It's defensive, cheap, brings dev in sync with main, and protects against the historically-recurring pattern of this fix being accidentally lost.

## Artifacts

- `audit/formal_verify.py` — Z3 proof script
- `audit/z3-proof-output.txt` — full proof output
- `test/Lender.t.sol::test_NEMESIS_PoC_zeroDebtNonZeroShares_unbacked_borrow` — concrete PoC demonstrating exploit IF the buggy state were reached (uses `vm.store` to construct it)
- `test/LenderInvariant.t.sol` — Foundry invariant test (passes; consistent with FV result)
