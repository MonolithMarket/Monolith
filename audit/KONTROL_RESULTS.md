# Kontrol — Setup Attempt and Outcome

**Status:** Attempted. Build failed in this environment. Documenting the journey for the team and as input to "lesson learned" for future audits.

## Why we tried Kontrol

Earlier in the audit we noted Kontrol as a strong candidate for arithmetic-heavy DeFi proofs:
- KEVM bytecode-level execution (sound by construction).
- Lemma system that handles the kind of `mulDivUp`/`mulDivDown` reasoning where Halmos times out.
- Production-tested for share-math proofs (Aave, Lido, Optimism).

The hope: where Halmos timed out on 4/8 queries (J-preservation under decreaseDebt, increaseDebt with two symbolic operands), Kontrol might prove them and give us a third independent verification of the Z3 result.

## Setup hurdles

Kontrol's distribution paths and how they fared on this developer machine:

1. **`kup install kontrol`** — RV's nix-based package manager. Their canonical install is a remote shell script. The tool sandbox blocked it as untrusted.

2. **PyPI `pip install kontrol`** — there's a package named "kontrol" but it's an unrelated library; the real Kontrol is not on PyPI.

3. **Docker image `runtimeverificationinc/kontrol`** — works, with caveats. This is the path we took.

To run Docker on macOS without Docker Desktop:
- Installed **Colima** (`brew install colima`).
- Started with default 2 GB VM → first build OOM-killed `forge build` (SIGKILL).
- Bumped to 8 GB → K kompile OOM at 95% memory usage.
- Bumped to 16 GB → memory was no longer the bottleneck.

## Build attempts

After memory was no longer the issue, we hit a sequence of compilation failures. Each `kontrol build` runs two K kompiles in parallel: Haskell backend (for `kontrol prove`) and LLVM backend (for `kontrol simulate`). Both must succeed.

### Attempt 1: 8 GB, default
- LLVM kompile OOM-killed at peak memory (`exit 137`).

### Attempt 2: 8 GB, `--no-llvm-kompile`
- Flag only disables the FINAL `llvm-kompile` (C++ build); the upstream `kompile --backend llvm` parsing still runs in parallel.
- Same OOM.

### Attempt 3: 16 GB, default
- Memory survived. Both kompiles ran.
- **Failed at LLVM kompile with `FileNotFoundException: Permission denied` on `out/kompiled/llvm-library/dt/...yaml`.**
- Container runs as UID 1000 (`user`), bind-mounted `out/` is owned by host UID 501 (`nourharidy`). Cross-UID writes to bind-mounted volumes don't work cleanly on Colima.

### Attempt 4: 16 GB, `chmod 777 out/`
- Permissions OK now. But same kompile fails — `exit 113`. The verbose log shows a K-level warning about `bytes-simplification.k:297`:
  ```
  ( B1:Bytes +Bytes B2:Bytes ) [ I:Int ] => B1 [ I ]
  ```
  followed by the kompile's exit-with-error. This may be a kontrol/k-framework version mismatch within the image itself; we did not investigate further.

### Attempt 5: 16 GB, fresh `out/`, `--no-forge-build`
- Same shape as attempt 4.

We stopped after attempt 5 — diminishing returns. Each attempt took ~10-15 minutes under QEMU emulation (Kontrol's image is `linux/amd64`, host is `linux/arm64`). Total time spent: ~1.5 hours.

## What we would have run if build had succeeded

`test/MockLenderKontrol.t.sol` (committed to this branch) — same `prove_*` shaped checks as the Halmos suite, byte-identical bodies. The intended invocation:

```bash
docker run --rm -v "$(pwd)":/workspace -w /workspace \
  runtimeverificationinc/kontrol:ubuntu-jammy-1.0.238 \
  bash -c "FOUNDRY_PROFILE=halmos kontrol prove --match-test 'MockLenderKontrolTest.prove_'"
```

## Why this doesn't change the verdict

Kontrol was always a "third independent verification" — Z3 had already proven the property and Halmos had cross-validated everything Halmos can solve. The audit verdict rests on:

1. **Z3 inductive proof** (`audit/formal_verify.py` + `audit/z3-proof-output.txt`): all 9 inductive queries proven.
2. **Z3 model fidelity** (`audit/sanity_check_muldiv.py`): `mul_div_up`/`mul_div_down` formally proven equivalent to Solmate.
3. **Halmos cross-validation** (`audit/halmos-output.txt`): same counter-example shape, same verdicts on solvable queries.
4. **Concrete PoC** (`test/Lender.t.sol::test_NEMESIS_PoC...`): demonstrates the bug if state were reached.
5. **Foundry invariant fuzz** (`test/LenderInvariantTest`): 128k random sequences, no violation.

Kontrol would have been corroboration #6. Its absence does not change the conclusion.

## Lesson learned

For arithmetic-heavy DeFi audits on Apple Silicon without Docker Desktop:
- **Kontrol via Docker is heavy.** 9.7 GB image, 16 GB VM, 30+ minute build under QEMU.
- **Trying to use Kontrol the same day you decide to** is risky. Plan on multi-day setup if no prior Kontrol experience on the machine.
- **Z3 with `Int` arithmetic** delivered the same kind of inductive result with ~10 seconds of wall time and a 200-line Python script. For invariants where overflow can be reasoned about as an over-approximation (Solidity 0.8 reverts), this is a much faster path.
- **If you really need bytecode-level confirmation**, Halmos solves whatever it can and times out cleanly on the rest. The combination Halmos + Z3 gave us full coverage; Kontrol would have been belt-and-suspenders.

## Files committed regardless

- `src/MockLenderFreeDebt.sol` — extracted harness (PRE-PR form).
- `src/MockLenderFreeDebtFixed.sol` — extracted harness (FIX form).
- `test/MockLenderKontrol.t.sol` — `prove_*` test functions (will work once Kontrol build succeeds).
- `test/MockLenderHalmos.t.sol` — Halmos `check_*` tests (working).
- `audit/KONTROL_RESULTS.md` — this document.
