#!/usr/bin/env python3
"""Independent reference implementation of the billing rules (Build Spec §07) using exact fractions.

It generates test/golden/*.json. The Dart core (packages/core) and the TypeScript port
(apps/api/src/money) must reproduce every expected value. Three separate implementations
agreeing is the point; do not generate these files from the Dart or TS code.

Rules:
  line amount   = price × qty (reversed lines count as 0)
  discount      = percent: half-up(subtotal × bp / 10000); flat: as given (≤ subtotal)
                  spread by floor(total × amount / subtotal); last line takes the remainder,
                  any excess over its amount moves backwards to lines with headroom
  GST per line  = half-up(taxable × rate / 10000); CGST = ceil(GST / 2); SGST = GST − CGST
  tip           = added after tax, untaxed
  round-off     = to the nearest rupee, halves up (x.50 → up); visible signed line
  total         = subtotal − discount + CGST + SGST + tip + round-off
Usage: python3 tool/gen_golden.py
"""
import json
import math
import os
from fractions import Fraction

RATES = {0, 500, 1200, 1800, 2800}


def half_up(x: Fraction) -> int:
    assert x >= 0
    return math.floor(x + Fraction(1, 2))


class Err(Exception):
    pass


def compute(lines, discount=None, tip=0):
    for l in lines:
        if l["qty"] <= 0:
            raise Err("bad_qty")
        if l["taxRateBp"] not in RATES:
            raise Err("bad_tax_rate")
    amounts = [0 if l.get("reversed") else l["pricePaise"] * l["qty"] for l in lines]
    sub = sum(amounts)
    if discount is None:
        d = 0
    elif discount["type"] == "percent":
        d = half_up(Fraction(sub * discount["bp"], 10000))
    else:
        d = discount["paise"]
        if d > sub:
            raise Err("discount_exceeds_subtotal")
    shares = [0] * len(amounts)
    if d and sub:
        for i in range(len(amounts) - 1):
            shares[i] = math.floor(Fraction(d * amounts[i], sub))
        shares[-1] = d - sum(shares[:-1])
        excess = shares[-1] - amounts[-1]
        if excess > 0:
            shares[-1] = amounts[-1]
            for i in range(len(amounts) - 2, -1, -1):
                if excess <= 0:
                    break
                take = min(amounts[i] - shares[i], excess)
                shares[i] += take
                excess -= take
    out, cg, sg = [], 0, 0
    for i, l in enumerate(lines):
        taxable = amounts[i] - shares[i]
        g = half_up(Fraction(taxable * l["taxRateBp"], 10000))
        c = math.ceil(Fraction(g, 2))
        s = g - c
        cg += c
        sg += s
        out.append({"amountPaise": amounts[i], "discountPaise": shares[i], "taxablePaise": taxable, "cgstPaise": c, "sgstPaise": s})
    before = sub - d + cg + sg + tip
    r = before % 100
    ro = 100 - r if r >= 50 else -r
    return {
        "lines": out, "subtotalPaise": sub, "discountPaise": d, "taxablePaise": sub - d, "cgstPaise": cg,
        "sgstPaise": sg, "tipPaise": tip, "roundOffPaise": ro, "totalPaise": before + ro,
    }


def pay(total, payments):
    remaining, change = total, 0
    for p in payments:
        if remaining == 0:
            raise Err("already_settled")
        if p["mode"] == "cash":
            use = min(p["tenderedPaise"], remaining)
            change += p["tenderedPaise"] - use
            remaining -= use
        else:
            if p["amountPaise"] > remaining:
                raise Err("overpayment")
            remaining -= p["amountPaise"]
    return {"paidPaise": total - remaining, "changePaise": change, "remainingPaise": remaining, "settled": remaining == 0}


L = lambda price, qty, bp, **kw: {"pricePaise": price, "qty": qty, "taxRateBp": bp, **kw}  # noqa: E731
PCT = lambda bp: {"type": "percent", "bp": bp}  # noqa: E731
FLAT = lambda p: {"type": "flat", "paise": p}  # noqa: E731

FILES = {
    "basic": [
        ("single_5pct", "Butter Chicken ₹340 × 1 at 5%", [L(34000, 1, 500)], None, 0),
        ("qty_3_naan", "Garlic Naan ₹60 × 3 at 5%", [L(6000, 3, 500)], None, 0),
        ("zero_rated_single", "Zero-rated item ₹100", [L(10000, 1, 0)], None, 0),
        ("zero_rated_many", "Only zero-rated items", [L(2500, 2, 0), L(4000, 1, 0)], None, 0),
        ("mixed_rates", "Mixed 5/12/18% lines", [L(34000, 1, 500), L(12000, 2, 1200), L(9000, 1, 1800)], None, 0),
        ("twelve_only", "12% drinks", [L(8000, 3, 1200)], None, 0),
        ("odd_tax_paisa_to_cgst", "GST of 9 paise splits 5 CGST / 4 SGST", [L(50, 1, 1800)], None, 0),
        ("paise_price_18", "Price with paise ₹123.45 at 18%", [L(12345, 1, 1800)], None, 0),
        ("rate_28", "28% slab", [L(19900, 1, 2800)], None, 0),
        ("reversed_line_excluded", "A reversed line stays on the order but adds nothing", [L(34000, 1, 500), L(22000, 1, 500, reversed=True)], None, 0),
        ("empty_bill", "No lines", [], None, 0),
        ("big_order", "Twelve lines across all rates", [L(34000 + i * 137, 1 + i % 3, [0, 500, 1200, 1800][i % 4]) for i in range(12)], None, 0),
    ],
    "rounding": [
        ("tax_exact_half_rounds_up", "10 paise at 5% = 0.5 paise → 1", [L(10, 1, 500)], None, 0),
        ("tax_below_half_rounds_down", "9 paise at 5% = 0.45 paise → 0", [L(9, 1, 500)], None, 0),
        ("tax_one_and_half", "30 paise at 5% = 1.5 → 2 (CGST 1, SGST 1)", [L(30, 1, 500)], None, 0),
        ("one_paisa_line", "1 paisa at 18% = 0.18 → 0", [L(1, 1, 1800)], None, 0),
        ("per_line_not_bill_level", "3 × 10-paise lines at 5%: per-line rounding gives 3 paise, bill-level would give 2", [L(10, 1, 500), L(10, 1, 500), L(10, 1, 500)], None, 0),
        ("roundoff_up_at_50", "Payable ends in .50 → +50", [L(1050, 1, 0)], None, 0),
        ("roundoff_down_at_49", "Payable ends in .49 → −49", [L(1049, 1, 0)], None, 0),
        ("roundoff_none", "Payable is whole rupees", [L(10000, 1, 0)], None, 0),
        ("roundoff_up_at_99", "Payable ends in .99 → +1", [L(1099, 1, 0)], None, 0),
        ("roundoff_after_tax", "Round-off applies to the taxed total: ₹105.79 → ₹106", [L(10075, 1, 500)], None, 0),
    ],
    "discounts": [
        ("percent_10_single", "10% off one line; tax computed after discount", [L(34000, 1, 500)], PCT(1000), 0),
        ("percent_10_mixed", "10% off mixed rates; discount spread pro rata, tax after discount", [L(34000, 1, 500), L(12000, 2, 1200), L(9000, 1, 1800)], PCT(1000), 0),
        ("flat_50_two_lines", "Flat ₹50 across ₹300 + ₹100", [L(30000, 1, 500), L(10000, 1, 1800)], FLAT(5000), 0),
        ("flat_remainder_to_last", "Flat ₹1 over three equal lines → 33/33/34", [L(1000, 1, 500), L(1000, 1, 500), L(1000, 1, 500)], FLAT(100), 0),
        ("excess_moves_back", "Last line too small to absorb its remainder; excess moves to the previous line", [L(3, 1, 500), L(3, 1, 500), L(1, 1, 500)], PCT(5000), 0),
        ("percent_100", "100% discount → nothing taxable, total 0", [L(34000, 1, 500), L(6000, 2, 500)], PCT(10000), 0),
        ("percent_12_5", "12.5% off (1250 bp) with paise prices", [L(12345, 1, 1800), L(6789, 2, 500)], PCT(1250), 0),
        ("flat_exceeds_subtotal", "Flat discount larger than the subtotal is rejected", [L(10000, 1, 500)], FLAT(10001), 0),
    ],
    "tips": [
        ("tip_untaxed", "₹20 tip is added after tax and not taxed", [L(34000, 1, 500)], None, 2000),
        ("tip_discount_roundoff", "Tip + discount + round-off together", [L(12345, 1, 1800), L(6000, 1, 500)], PCT(1000), 1550),
    ],
}

PAYMENT_CASES = [
    ("cash_exact", "Exact cash", [L(34000, 1, 500)], [{"mode": "cash", "tenderedPaise": 35700}]),
    ("cash_with_change", "₹500 note for ₹357", [L(34000, 1, 500)], [{"mode": "cash", "tenderedPaise": 50000}]),
    ("split_cash_upi", "Pay across modes: ₹200 UPI then cash for the rest", [L(34000, 1, 500)], [{"mode": "upi", "amountPaise": 20000}, {"mode": "cash", "tenderedPaise": 20000}]),
    ("split_three_modes", "UPI + card + cash with change", [L(34000, 1, 500), L(12000, 2, 1200)], [{"mode": "upi", "amountPaise": 30000}, {"mode": "card", "amountPaise": 20000}, {"mode": "cash", "tenderedPaise": 20000}]),
    ("upi_overpay_rejected", "UPI cannot exceed the amount due", [L(34000, 1, 500)], [{"mode": "upi", "amountPaise": 40000}]),
    ("partial_unsettled", "Part-paid bill keeps a remainder", [L(34000, 1, 500)], [{"mode": "card", "amountPaise": 10000}]),
]


def main():
    here = os.path.join(os.path.dirname(__file__), "..", "test", "golden")
    os.makedirs(here, exist_ok=True)
    total = 0
    for name, cases in FILES.items():
        vecs = []
        for cid, desc, lines, disc, tip in cases:
            v = {"id": cid, "description": desc, "lines": lines, "discount": disc, "tipPaise": tip}
            try:
                v["expected"] = compute(lines, disc, tip)
            except Err as e:
                v["expected"] = {"error": str(e)}
            vecs.append(v)
        json.dump(vecs, open(os.path.join(here, f"{name}.json"), "w"), indent=2, ensure_ascii=False)
        total += len(vecs)
    vecs = []
    for cid, desc, lines, payments in PAYMENT_CASES:
        bill = compute(lines)
        v = {"id": cid, "description": desc, "lines": lines, "discount": None, "tipPaise": 0, "payments": payments, "expected": bill}
        try:
            v["expected"]["payments"] = pay(bill["totalPaise"], payments)
        except Err as e:
            v["expected"]["payments"] = {"error": str(e)}
        vecs.append(v)
    json.dump(vecs, open(os.path.join(here, "payments.json"), "w"), indent=2, ensure_ascii=False)
    total += len(vecs)
    print(f"wrote {total} golden vectors")


if __name__ == "__main__":
    main()
