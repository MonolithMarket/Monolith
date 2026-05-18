#!/usr/bin/env python3
"""
Sanity-check the Z3 model's mul_div_up / mul_div_down against
Solmate's exact assembly formula via Python.

Solmate's mulDivUp:
    z = (mod(x*y, denom) > 0 ? 1 : 0) + div(x*y, denom)

Solmate's mulDivDown:
    z = div(x*y, denom)
"""

import sys
sys.path.insert(0, '/Users/nourharidy/.local/pipx/venvs/z3-solver/lib/python3.13/site-packages')
from z3 import *

# Z3 model versions
def z3_ceil_div(x, y):
    return If(x % y == 0, x / y, x / y + 1)

def z3_mul_div_up(x, y, z):
    return z3_ceil_div(x * y, z)

def z3_mul_div_down(x, y, z):
    return (x * y) / z

# Solmate ground truth (Python translation of the assembly)
def solmate_mul_div_up(x, y, denom):
    if denom == 0:
        raise ZeroDivisionError("denom == 0 reverts in Solidity")
    return ((x*y) % denom > 0) * 1 + (x*y) // denom

def solmate_mul_div_down(x, y, denom):
    if denom == 0:
        raise ZeroDivisionError("denom == 0 reverts in Solidity")
    return (x*y) // denom


# Step 1: Verify Z3 model agrees with Solmate for representative concrete values
def check_concrete():
    print("Concrete sanity check — Z3 ?= Solmate")
    print("-" * 50)
    # Test values spanning edge cases
    test_cases = [
        (0, 0, 1),       # x=0
        (0, 5, 7),
        (1, 1, 1),
        (1, 1, 2),       # ceil-correction case
        (1, 2, 3),
        (5, 7, 2),
        (10, 10, 10),
        (100, 99, 100),
        (1000000000, 999999999, 1000000000),
        # The Z3 counter-example values
        (1, 1, 2),       # Part 1 CE: D=1, S=2, X=1
        (923562806233358076, 733670991145484225, 923562806233358077),  # earlier BV CE
    ]
    failures = 0
    for (x, y, denom) in test_cases:
        # Solmate truth
        s_up = solmate_mul_div_up(x, y, denom)
        s_dn = solmate_mul_div_down(x, y, denom)
        # Z3 model
        s = Solver()
        z3_up_val = z3_mul_div_up(IntVal(x), IntVal(y), IntVal(denom))
        z3_dn_val = z3_mul_div_down(IntVal(x), IntVal(y), IntVal(denom))
        s.add(z3_up_val == s_up)
        s.add(z3_dn_val == s_dn)
        result = s.check()
        if result != sat:
            # Attempt to find the actual Z3 value
            s2 = Solver()
            up_var, dn_var = Int("up"), Int("dn")
            s2.add(up_var == z3_mul_div_up(IntVal(x), IntVal(y), IntVal(denom)))
            s2.add(dn_var == z3_mul_div_down(IntVal(x), IntVal(y), IntVal(denom)))
            s2.check()
            m = s2.model()
            print(f"  ✗ MISMATCH: x={x}, y={y}, denom={denom}")
            print(f"      Solmate up={s_up}, dn={s_dn}")
            print(f"      Z3      up={m[up_var]}, dn={m[dn_var]}")
            failures += 1
        else:
            print(f"  ✓ x={x}, y={y}, denom={denom} → up={s_up}, dn={s_dn}")
    print(f"\nFailures: {failures}")
    return failures


# Step 2: SMT-prove equivalence for ALL non-negative inputs
def check_equivalence_smt():
    print("\nSMT proof — Z3 model ≡ Solmate algebraic form for ALL inputs")
    print("-" * 50)
    x, y, denom = Ints("x y denom")

    # Solmate ground truth (algebraic form)
    # mod(x*y, denom) > 0 ? 1 : 0
    solmate_up = If((x*y) % denom > 0, IntVal(1), IntVal(0)) + (x*y) / denom
    solmate_dn = (x*y) / denom

    z3_up = z3_mul_div_up(x, y, denom)
    z3_dn = z3_mul_div_down(x, y, denom)

    # Prove: for all x, y, denom >= 0 with denom > 0, z3_up == solmate_up and z3_dn == solmate_dn
    s = Solver()
    s.set("timeout", 60000)
    s.add(x >= 0, y >= 0, denom > 0)
    s.add(Or(z3_up != solmate_up, z3_dn != solmate_dn))
    res = s.check()
    if res == unsat:
        print("  ✓ PROVEN EQUIVALENT for all non-neg x, y, denom > 0")
        return True
    elif res == sat:
        m = s.model()
        print(f"  ✗ DIVERGENCE FOUND: x={m[x]}, y={m[y]}, denom={m[denom]}")
        return False
    else:
        print("  ? UNKNOWN")
        return None


if __name__ == "__main__":
    check_concrete()
    check_equivalence_smt()
