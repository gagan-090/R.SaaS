import 'totals.dart';

enum PaymentMode { cash, upi, card }

/// Cash carries the amount tendered; UPI and card carry the exact amount charged.
class PaymentInput {
  const PaymentInput.cash(int this.tenderedPaise)
      : mode = PaymentMode.cash,
        amountPaise = null;
  const PaymentInput.upi(int this.amountPaise)
      : mode = PaymentMode.upi,
        tenderedPaise = null;
  const PaymentInput.card(int this.amountPaise)
      : mode = PaymentMode.card,
        tenderedPaise = null;

  final PaymentMode mode;
  final int? amountPaise;
  final int? tenderedPaise;

  factory PaymentInput.fromJson(Map<String, Object?> j) => switch (j['mode']) {
        'cash' => PaymentInput.cash(j['tenderedPaise']! as int),
        'upi' => PaymentInput.upi(j['amountPaise']! as int),
        'card' => PaymentInput.card(j['amountPaise']! as int),
        _ => throw BillingError('bad_mode', 'unknown payment mode ${j['mode']}'),
      };
}

class AppliedPayment {
  const AppliedPayment(this.mode, this.appliedPaise, this.changePaise);
  final PaymentMode mode;
  final int appliedPaise;
  final int changePaise;
}

class PaymentSummary {
  const PaymentSummary({required this.applied, required this.paidPaise, required this.changePaise, required this.remainingPaise});
  final List<AppliedPayment> applied;
  final int paidPaise;
  final int changePaise;
  final int remainingPaise;
  bool get settled => remainingPaise == 0;

  Map<String, Object> toJson() => {
        'paidPaise': paidPaise,
        'changePaise': changePaise,
        'remainingPaise': remainingPaise,
        'settled': settled,
      };
}

/// Applies payments in order against [totalPaise]. One bill may be paid across several modes.
/// Cash applies min(tendered, remaining) and returns the rest as change; UPI/card may not exceed the remainder.
PaymentSummary applyPayments(int totalPaise, List<PaymentInput> payments) {
  var remaining = totalPaise;
  var change = 0;
  final applied = <AppliedPayment>[];
  for (final p in payments) {
    if (remaining == 0) throw BillingError('already_settled', 'bill is already fully paid');
    if (p.mode == PaymentMode.cash) {
      final tendered = p.tenderedPaise!;
      if (tendered <= 0) throw BillingError('bad_amount', 'tendered amount must be positive');
      final use = tendered < remaining ? tendered : remaining;
      applied.add(AppliedPayment(p.mode, use, tendered - use));
      change += tendered - use;
      remaining -= use;
    } else {
      final amt = p.amountPaise!;
      if (amt <= 0) throw BillingError('bad_amount', 'amount must be positive');
      if (amt > remaining) throw BillingError('overpayment', '${p.mode.name} amount exceeds the amount due');
      applied.add(AppliedPayment(p.mode, amt, 0));
      remaining -= amt;
    }
  }
  return PaymentSummary(applied: applied, paidPaise: totalPaise - remaining, changePaise: change, remainingPaise: remaining);
}
