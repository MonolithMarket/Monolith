#!/usr/bin/env python3
"""
Formal verification of free-debt invariants in Lender.sol (pre-PR / vulnerable form).

Uses Z3 with unbounded INTEGERS (much faster than BVs for arithmetic).
Solidity 0.8 reverts on overflow, so we model arithmetic as mathematical (no wrap).

Goals:
  G1. Prove: I := (D = 0 ⇒ S = 0) is inductive across all operations.
  G2. Prove: J := (D ≥ S) is inductive (stronger; implies G1).
  G3. If a counter-example exists, surface it concretely.
"""

import sys
sys.path.insert(0, '/Users/nourharidy/.local/pipx/venvs/z3-solver/lib/python3.13/site-packages')
from z3 import *

# Use unbounded Ints. Solidity 0.8 reverts on overflow, so integer semantics is sound.
# We add bounds just to keep models reasonable.
def U(name): return Int(name)

def ceil_div(x, y):
    """ceil(x/y) for non-negative ints, y > 0"""
    return If(x % y == 0, x / y, x / y + 1)

def floor_div(x, y):
    return x / y

def mul_div_up(x, y, z):
    return ceil_div(x * y, z)

def mul_div_down(x, y, z):
    return floor_div(x * y, z)

def prove(label, build_fn, timeout_sec=120):
    print(f"[ {label} ]", flush=True)
    s = Solver()
    s.set("timeout", timeout_sec * 1000)
    claim = build_fn(s)
    s.add(Not(claim))
    res = s.check()
    if res == unsat:
        print(f"  ✓ PROVEN INDUCTIVE\n", flush=True)
        return "proven"
    elif res == sat:
        print(f"  ✗ COUNTER-EXAMPLE:", flush=True)
        m = s.model()
        for d in sorted(m, key=lambda x: x.name()):
            print(f"      {d} = {m[d]}", flush=True)
        print()
        return "ce"
    else:
        print(f"  ? UNKNOWN (timeout/undecidable)\n", flush=True)
        return "?"


def add_invariant_pre(s, D, S):
    """I := D = 0 ⇒ S = 0  ⟺  D > 0 ∨ S = 0"""
    s.add(Or(D > 0, S == 0))

def add_dge_s(s, D, S):
    s.add(D >= S)

def add_nonneg(s, *vs):
    for v in vs: s.add(v >= 0)


# ============================================================================
print("=" * 70, flush=True)
print("PART 1: invariant I := (D = 0 ⇒ S = 0)", flush=True)
print("=" * 70, flush=True)

# 1. increaseDebt PRE-PR
def f_inc_prepr(s):
    D, S, amount = U("D"), U("S"), U("amount")
    add_nonneg(s, D, S, amount)
    add_invariant_pre(s, D, S)
    shares = If(D == 0, amount, mul_div_up(amount, S, D))
    Dp, Sp = D + amount, S + shares
    return Or(Dp > 0, Sp == 0)

prove("increaseDebt PRE-PR preserves I", f_inc_prepr)

# 1b. increaseDebt FIX
def f_inc_fix(s):
    D, S, amount = U("D"), U("S"), U("amount")
    add_nonneg(s, D, S, amount)
    add_invariant_pre(s, D, S)
    shares = If(D == 0,
                If(S == 0, amount, amount * S),
                mul_div_up(amount, S, D))
    Dp, Sp = D + amount, S + shares
    return Or(Dp > 0, Sp == 0)

prove("increaseDebt FIX preserves I", f_inc_fix)

# 2. decreaseDebt non-max
def f_dec_nonmax(s):
    D, S, X, amount = U("D"), U("S"), U("X"), U("amount")
    add_nonneg(s, D, S, X, amount)
    add_invariant_pre(s, D, S)
    s.add(D > 0)
    s.add(X <= S)
    user_debt = If(S == 0, IntVal(0), mul_div_up(X, D, S))
    s.add(amount <= user_debt)
    shares = mul_div_down(amount, S, D)
    s.add(shares <= X)
    Sp = If(S <= shares, IntVal(0), S - shares)
    Dp = If(D <= amount, IntVal(0), D - amount)
    return Or(Dp > 0, Sp == 0)

prove("decreaseDebt non-max preserves I", f_dec_nonmax)

# 3. decreaseDebt max
def f_dec_max(s):
    D, S, X = U("D"), U("S"), U("X")
    add_nonneg(s, D, S, X)
    add_invariant_pre(s, D, S)
    s.add(X > 0)
    s.add(S > 0)
    s.add(X <= S)
    shares = X
    amount = mul_div_up(X, D, S)
    Sp = If(S <= shares, IntVal(0), S - shares)
    Dp = If(D <= amount, IntVal(0), D - amount)
    return Or(Dp > 0, Sp == 0)

prove("decreaseDebt max preserves I", f_dec_max)

# 4. writeOff redistribute
def f_wo_redist(s):
    D, S, debt, totalDebt = U("D"), U("S"), U("debt"), U("totalDebt")
    add_nonneg(s, D, S, debt, totalDebt)
    add_invariant_pre(s, D, S)
    s.add(totalDebt > 0)
    s.add(D <= totalDebt)
    fdi = mul_div_down(debt, D, totalDebt)
    Dp = D + fdi
    Sp = S
    return Or(Dp > 0, Sp == 0)

prove("writeOff redistribute preserves I", f_wo_redist)


# ============================================================================
print("=" * 70, flush=True)
print("PART 2: stronger invariant J := (D ≥ S) — implies I", flush=True)
print("=" * 70, flush=True)

# decreaseDebt non-max preserves J
def g_dec_nonmax(s):
    D, S, X, amount = U("D"), U("S"), U("X"), U("amount")
    add_nonneg(s, D, S, X, amount)
    add_dge_s(s, D, S)
    s.add(D > 0)
    s.add(X <= S)
    user_debt = If(S == 0, IntVal(0), mul_div_up(X, D, S))
    s.add(amount <= user_debt)
    shares = mul_div_down(amount, S, D)
    s.add(shares <= X)
    Sp = If(S <= shares, IntVal(0), S - shares)
    Dp = If(D <= amount, IntVal(0), D - amount)
    return Dp >= Sp

prove("decreaseDebt non-max preserves J (D >= S)", g_dec_nonmax)

# decreaseDebt max preserves J
def g_dec_max(s):
    D, S, X = U("D"), U("S"), U("X")
    add_nonneg(s, D, S, X)
    add_dge_s(s, D, S)
    s.add(X > 0)
    s.add(S > 0)
    s.add(X <= S)
    shares = X
    amount = mul_div_up(X, D, S)
    Sp = If(S <= shares, IntVal(0), S - shares)
    Dp = If(D <= amount, IntVal(0), D - amount)
    return Dp >= Sp

prove("decreaseDebt max preserves J", g_dec_max)

# increaseDebt PRE-PR preserves J
def g_inc_prepr(s):
    D, S, amount = U("D"), U("S"), U("amount")
    add_nonneg(s, D, S, amount)
    add_dge_s(s, D, S)
    shares = If(D == 0, amount, mul_div_up(amount, S, D))
    Dp = D + amount
    Sp = S + shares
    return Dp >= Sp

prove("increaseDebt PRE-PR preserves J", g_inc_prepr)

# writeOff redistribute preserves J
def g_wo_redist(s):
    D, S, debt, totalDebt = U("D"), U("S"), U("debt"), U("totalDebt")
    add_nonneg(s, D, S, debt, totalDebt)
    add_dge_s(s, D, S)
    s.add(totalDebt > 0)
    s.add(D <= totalDebt)
    fdi = mul_div_down(debt, D, totalDebt)
    Dp = D + fdi
    Sp = S
    return Dp >= Sp

prove("writeOff redistribute preserves J", g_wo_redist)


# ============================================================================
# CRITICAL: Can D < S be reached? Show via concrete counter-example check.
print("=" * 70, flush=True)
print("PART 3: Reachability of D < S via valid operations", flush=True)
print("=" * 70, flush=True)
print("""
If we cannot prove (J ⇒ J' for every operation), check whether the failing
operation can REACH a state with D < S from a state with D >= S.
This is what the bug ultimately needs.
""", flush=True)

# An adversary's claim: starting from D >= S (which DOES hold initially since D=S=0),
# there exists an operation sequence reaching D=0, S>0.
# We've proven each individual operation preserves J above (or shown counter-example).
# If ALL preserve J, then D < S is unreachable, hence D=0, S>0 is unreachable.

# ============================================================================
print("=" * 70, flush=True)
print("DONE", flush=True)
print("=" * 70, flush=True)
