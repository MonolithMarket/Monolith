# Meta-Audit: Nemesis-style Review of `audit/formal_verify.py`

**Goal:** Determine whether the Z3 model in `formal_verify.py` faithfully captures the Solidity semantics of `src/Lender.sol` (pre-PR / vulnerable form). Any inaccuracy could mean the formal proof's verdict ("PR fix is unreachable") is wrong.

**Method:** Nemesis-style audit — Phase 0 recon → Phase 1 dual mapping → Phase 2 line-by-line Feynman interrogation → Phase 3 state cross-check → Phase 4 feedback loop → Phase 6 verification.

---

## Phase 0 — Recon

**Attack goals (for the meta-audit):**
1. Find an inaccuracy that could turn a real bug into a "proven safe" verdict (false negative — most dangerous).
2. Find a missing mutation path the model doesn't cover.
3. Find a precondition assumed by the model that real callers don't enforce.

**Coupling hypothesis:**
- Z3 `D` ↔ Solidity `totalFreeDebt`
- Z3 `S` ↔ Solidity `totalFreeDebtShares`
- Z3 `X` ↔ Solidity `freeDebtShares[account]` (one borrower's shares)
- Z3 `mul_div_up`/`mul_div_down` ↔ Solmate `mulDivUp`/`mulDivDown`
- Z3 clamps `If(D <= amount, 0, ...)` ↔ Solidity ternary clamps

---

## Phase 1 — Dual Mapping

### 1A. Function-State matrix (FREE debt only)

| Solidity site | Action | Modeled in Z3 by |
|---|---|---|
| Lender.sol:557 `totalFreeDebt += amount` | increaseDebt | `f_inc_prepr`, `f_inc_fix`, `g_inc_prepr` |
| Lender.sol:558 `totalFreeDebtShares += shares` | increaseDebt | same as above |
| Lender.sol:596 `S = S<=shares ? 0 : S-shares` | decreaseDebt clamp | `f_dec_nonmax`/`max`, `g_dec_*` |
| Lender.sol:597 `D = D<=amount ? 0 : D-amount` | decreaseDebt clamp | same as above |
| Lender.sol:403 `totalFreeDebt += freeDebtIncrease` | writeOff redistribute | `f_wo_redist`, `g_wo_redist` |

### 1B. Coupled state pairs

- `totalFreeDebt` ↔ `totalFreeDebtShares` (the invariant under audit)
- `totalFreeDebtShares` ↔ `Σ freeDebtShares[account]` (sum-invariant; encoded as `X ≤ S` in Z3)

### 1C. Cross-reference

**Every FREE-D/S writer in Solidity is reachable through one of:** `increaseDebt`, `decreaseDebt`, `writeOff`. All three are modeled. No missing mutation path. ✓

---

## Phase 2 — Feynman Interrogation

### `mul_div_up` / `mul_div_down` faithfulness

**Solmate ground truth** (lib/solmate/src/utils/FixedPointMathLib.sol:53-69):
```
mulDivUp(x, y, denom) = (mod(x*y, denom) > 0 ? 1 : 0) + div(x*y, denom)
mulDivDown(x, y, denom) = div(x*y, denom)
```

**Z3 model:**
```python
ceil_div(x, y) = if x % y == 0: x/y else x/y + 1
mul_div_up(x, y, z) = ceil_div(x*y, z)
mul_div_down(x, y, z) = (x*y) / z
```

**Verification** (`audit/sanity_check_muldiv.py`):
- 11 concrete test cases including the actual Z3 counter-example values — **all match**.
- **SMT-proven equivalent for ALL non-negative inputs with denom > 0** (Z3 returned `unsat` on `Or(z3_up != solmate_up, z3_dn != solmate_dn)`).

**Verdict: ✓ FAITHFUL**

### Underflow clamps

**Solidity:** `S = S <= shares ? 0 : S - shares`, `D = D <= amount ? 0 : D - amount`
**Z3:** `Sp = If(S <= shares, IntVal(0), S - shares)`, `Dp = If(D <= amount, ...)`

**Verdict: ✓ FAITHFUL** (textual equivalence)

### Caller bound preconditions

The Z3 model adds preconditions that real Solidity callers must enforce. Verified:

| Precondition | Solidity enforcement | Verdict |
|---|---|---|
| `D > 0` (non-max path) | mulDivDown reverts on denom=0 | ✓ |
| `X ≤ S` | sum invariant — `Σ freeDebtShares[a] = totalFreeDebtShares` | ✓ |
| `amount ≤ user_debt` | adjust:261-266, liquidate:341-349, redeem:436-440 all cap at `getDebtOf(borrower)` | ✓ |
| `shares ≤ X` | underflow on `freeDebtShares[a] -= shares` reverts | ✓ |
| `S > 0` (max path) | `getDebtOf` returns 0 if S=0 → amount=0 → trivial no-op (excluded for soundness) | ✓ |
| `totalDebt > 0` (writeOff redistribute) | Solidity `if (totalDebt > 0)` guard | ✓ |

**Verdict: ✓ ALL PRECONDITIONS JUSTIFIED**

### Solidity 0.8 overflow ↔ Z3 unbounded Int

- Solidity 0.8 reverts on overflow → state unchanged → invariant trivially preserved.
- Z3 unbounded Int never overflows → models the operation as if it succeeded.
- **Direction:** Z3 considers a SUPERSET of Solidity's reachable post-states. If Z3 proves invariant on the superset, it holds on the actual reachable subset.

**Verdict: ✓ SOUND OVER-APPROXIMATION**

### MaxBorrowDelta require (Lender.sol:565)

```solidity
require(actualDebtIncrease <= maxAllowedDebtIncrease, "Borrow delta exceeds max");
```

This `require` reverts the entire tx if it fails (state unchanged). Z3 model omits this check — proves invariant for ALL increaseDebt calls regardless of delta. If invariant holds for all, it holds when the require also holds.

**Verdict: ✓ SOUND OVER-APPROXIMATION**

---

## Phase 3 — State Cross-Check

### Mutation matrix (FREE debt) — gap check

Every FREE D/S writer in Solidity is one of:
1. `increaseDebt` (touches both D and S together) — modeled
2. `decreaseDebt` clamps (touches both, possibly asymmetrically) — modeled
3. `writeOff` redistribute (touches D only, NOT S) — modeled, asymmetry preserved

**No gap.** ✓

### Parallel paths

Indirect callers (adjust, liquidate, redeem, writeOff, setRedemptionStatus) all funnel through `increaseDebt` / `decreaseDebt`. Mutator-level proof covers them transitively.

**Verdict: ✓ ALL PATHS COVERED**

### Operation ordering within decreaseDebt

In Solidity:
```solidity
freeDebtShares[account] -= shares;  // step 1, may revert
totalFreeDebtShares = ...;          // step 2
totalFreeDebt = ...;                // step 3
```

In Z3, both clamps computed in parallel from pre-state. This matches Solidity since both clamps READ from pre-shares and pre-amount values (not from each other). ✓

---

## Phase 4 — Feedback Loop

### Step A: State gaps → Feynman re-interrogation

- `f_wo_redist` modifies D but not S — is this a gap?
  - **Verdict:** No. Solidity does the same thing. The asymmetry is intentional (write-off redistributes debt without minting new shares).

### Step B: Feynman findings → State expansion

- The Phase-1 counter-example for `decreaseDebt max` (D=1, S=2, X=1) requires `D < S`.
- State Mapper question: does `D < S` couple to anything we haven't checked?
- **Answer:** `D ≥ S` is itself an invariant (proven in Part 2). So `D < S` is never reachable. No further coupling to chase.

### Step C: Masking code

- The `<= ? 0 :` clamps are masking code. WHY do they exist?
- **Answer:** Defensive guard against the very state (D=0, S>0 / underflow) that the inductive proof shows is unreachable. The clamps mask a state that cannot arise. Result: defensive but never exercised.

### Step D: Convergence

No new findings emerged. Loop converges. ✓

---

## Phase 6 — Verification of meta-audit findings

### Finding M-001: PAID debt invariant out of scope

**Severity:** LOW
**What:** Z3 model only proves invariant for FREE debt. PAID debt has the same code pattern and the PR also doesn't fix the PAID branch.
**Why this is OK for the verdict:**
- The PR question is specifically about the FREE branch fix.
- The PAID branch has the same code pattern; by symmetry, the same proof would yield the same conclusion.
- Adding `accrueInterest` (Lender.sol:224 `totalPaidDebt += interest`) as a fourth mutator would not violate the inductive proof — it only adds to D_paid without touching S_paid, same shape as `writeOff redistribute`.

**Recommendation:** If a complete audit is needed, replicate the PART 2 proofs for PAID debt with the additional `accrueInterest` mutator. Current verdict stands.

### Finding M-002: `g_inc_fix` not in PART 2

**Severity:** INFORMATIONAL
**What:** PART 2 proves PRE-PR `increaseDebt` preserves `J = D≥S`, but doesn't prove the FIX preserves J.
**Why this is OK:**
- Under the precondition `J: D≥S`, the FIX behaves identically to PRE-PR. Both have `shares = amount` when `D=0` (and J forces `S=0` too, so the FIX's `if (S==0)` branch fires). Identical behavior under J means same proof works.
- Doesn't affect verdict (the proof is about the PRE-PR code being correct; FIX is just defensive parity).

### Finding M-003: Solmate overflow check redundancy

**Severity:** INFORMATIONAL
**What:** Solmate's `mulDivUp` has an explicit overflow check (`x <= MAX_UINT256 / y`). Solidity 0.8 already reverts on `*` overflow — Solmate's check is belt-and-suspenders. Z3 model uses unbounded Int, so neither check applies.
**Why this is OK:** Sound over-approximation. If Z3 proves invariant for arbitrary inputs, it holds for the bounded uint256 subset. Worst case: Z3 produces a counter-example using ridiculous values; we'd see it and judge reachability.

### Verification of `mulDivUp`/`mulDivDown` equivalence

**Method:** SMT proof via Z3 (`audit/sanity_check_muldiv.py`).
**Result:** ✓ FORMALLY PROVEN equivalent to Solmate for all non-negative inputs with denom > 0.

---

## CONCLUSION — Meta-audit Verdict

**The Z3 formal verification model in `audit/formal_verify.py` faithfully captures the Solidity semantics of `src/Lender.sol` for the FREE debt invariant.**

Specifically:
- ✓ `mul_div_up` / `mul_div_down` are SMT-proven equivalent to Solmate.
- ✓ All 5 FREE D/S write sites in Solidity are covered by 3 modeled operations.
- ✓ All Z3 preconditions (caller bounds, sum invariants) are justified by Solidity callers.
- ✓ Underflow clamps are textually equivalent.
- ✓ Z3 unbounded-Int model is a sound over-approximation of Solidity 0.8 reverting arithmetic.
- ✓ All indirect callers (adjust, liquidate, redeem, writeOff, setRedemptionStatus) funnel through modeled mutators.
- ✓ The proof structure (J inductive → J always holds → I always holds) is logically valid.

**No issues were found that would invalidate the proof's conclusion: the bug state `D=0, S>0` is formally unreachable in current dev code.**

The original verdict stands:
- The PR fix is **defensive only** — bug not reachable.
- Apply the PR for parity with `main`, defense-in-depth, and regression resistance.

---

## Artifacts

- `audit/formal_verify.py` — Z3 inductive proof (subject of this meta-audit)
- `audit/sanity_check_muldiv.py` — formal proof that Z3's `mul_div_up`/`mul_div_down` ≡ Solmate's
- `audit/z3-proof-output.txt` — original proof run output
- `audit/VERDICT.md` — original audit verdict
- `audit/META_AUDIT.md` — this document
