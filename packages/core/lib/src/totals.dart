import 'money.dart';

/// GST slabs supported by Chef's Defaults (basis points). 28% is allowed for completeness.
const gstRatesBp = <int>{0, 500, 1200, 1800, 2800};

class BillingError implements Exception {
  BillingError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'BillingError($code): $message';
}

/// One priced line as it sits on an order: price and tax rate are snapshots taken when the line was added.
class LineInput {
  const LineInput({required this.pricePaise, required this.qty, required this.taxRateBp, this.reversed = false});

  final int pricePaise;
  final int qty;
  final int taxRateBp;

  /// Reversed lines stay on the order for traceability but contribute nothing to totals.
  final bool reversed;

  int get amountPaise => reversed ? 0 : pricePaise * qty;

  factory LineInput.fromJson(Map<String, Object?> j) => LineInput(
        pricePaise: j['pricePaise']! as int,
        qty: j['qty']! as int,
        taxRateBp: j['taxRateBp']! as int,
        reversed: (j['reversed'] as bool?) ?? false,
      );
}

sealed class Discount {
  const Discount();
  factory Discount.fromJson(Map<String, Object?>? j) {
    if (j == null) return const NoDiscount();
    return switch (j['type']) {
      'percent' => PercentDiscount(j['bp']! as int),
      'flat' => FlatDiscount(j['paise']! as int),
      _ => throw BillingError('bad_discount', 'unknown discount type ${j['type']}'),
    };
  }
}

class NoDiscount extends Discount {
  const NoDiscount();
}

/// Percentage in basis points (1000 = 10%).
class PercentDiscount extends Discount {
  const PercentDiscount(this.bp);
  final int bp;
}

class FlatDiscount extends Discount {
  const FlatDiscount(this.paise);
  final int paise;
}

class LineTotals {
  const LineTotals({
    required this.amountPaise,
    required this.discountPaise,
    required this.taxablePaise,
    required this.cgstPaise,
    required this.sgstPaise,
  });
  final int amountPaise;
  final int discountPaise;
  final int taxablePaise;
  final int cgstPaise;
  final int sgstPaise;

  Map<String, int> toJson() => {
        'amountPaise': amountPaise,
        'discountPaise': discountPaise,
        'taxablePaise': taxablePaise,
        'cgstPaise': cgstPaise,
        'sgstPaise': sgstPaise,
      };
}

class BillTotals {
  const BillTotals({
    required this.lines,
    required this.subtotalPaise,
    required this.discountPaise,
    required this.taxablePaise,
    required this.cgstPaise,
    required this.sgstPaise,
    required this.tipPaise,
    required this.roundOffPaise,
    required this.totalPaise,
  });

  final List<LineTotals> lines;
  final int subtotalPaise;
  final int discountPaise;
  final int taxablePaise;
  final int cgstPaise;
  final int sgstPaise;
  final int tipPaise;

  /// Visible round-off line to the nearest rupee, in [-49, +50] paise.
  final int roundOffPaise;
  final int totalPaise;

  Money get total => Money(totalPaise);

  Map<String, Object> toJson() => {
        'lines': lines.map((l) => l.toJson()).toList(),
        'subtotalPaise': subtotalPaise,
        'discountPaise': discountPaise,
        'taxablePaise': taxablePaise,
        'cgstPaise': cgstPaise,
        'sgstPaise': sgstPaise,
        'tipPaise': tipPaise,
        'roundOffPaise': roundOffPaise,
        'totalPaise': totalPaise,
      };
}

/// Splits [total] discount across [amounts] in proportion (floor), the last line absorbing the remainder.
/// If the remainder would exceed the last line's amount, the excess moves to earlier lines that still
/// have headroom (from the end backwards), so no line's taxable value goes negative.
List<int> allocateDiscount(List<int> amounts, int total) {
  final sum = amounts.fold<int>(0, (a, b) => a + b);
  if (total == 0 || sum == 0) return List.filled(amounts.length, 0);
  final shares = <int>[];
  for (var i = 0; i < amounts.length; i++) {
    shares.add(i == amounts.length - 1 ? 0 : mulDivFloor(total, amounts[i], sum));
  }
  final allocated = shares.fold<int>(0, (a, b) => a + b);
  shares[shares.length - 1] = total - allocated;
  var excess = shares.last - amounts.last;
  if (excess > 0) {
    shares[shares.length - 1] = amounts.last;
    for (var i = amounts.length - 2; i >= 0 && excess > 0; i--) {
      final room = amounts[i] - shares[i];
      final take = room < excess ? room : excess;
      shares[i] += take;
      excess -= take;
    }
  }
  return shares;
}

/// GST on one line: half-up to the paisa on the taxable value, then split CGST/SGST (odd paisa → CGST).
({int cgst, int sgst}) gstSplit(int taxablePaise, int rateBp) {
  final tax = mulDivHalfUp(taxablePaise, rateBp, 10000);
  final cgst = (tax + 1) ~/ 2;
  return (cgst: cgst, sgst: tax - cgst);
}

/// Nearest rupee, halves up: x.50 → up. Returns the signed adjustment in paise.
int roundOffToRupee(int paise) {
  if (paise < 0) throw BillingError('negative_total', 'bill total cannot be negative');
  final r = paise % 100;
  return r >= 50 ? 100 - r : -r;
}

/// Grand total = subtotal − discount + CGST + SGST + tip + round-off. Pure function; all integer paise.
BillTotals computeBill(List<LineInput> lines, {Discount discount = const NoDiscount(), int tipPaise = 0}) {
  for (final l in lines) {
    if (l.qty <= 0) throw BillingError('bad_qty', 'quantity must be positive');
    if (l.pricePaise < 0) throw BillingError('bad_price', 'price cannot be negative');
    if (!gstRatesBp.contains(l.taxRateBp)) throw BillingError('bad_tax_rate', 'unsupported GST rate ${l.taxRateBp}bp');
  }
  if (tipPaise < 0) throw BillingError('bad_tip', 'tip cannot be negative');
  final amounts = lines.map((l) => l.amountPaise).toList();
  final subtotal = amounts.fold<int>(0, (a, b) => a + b);

  final discountTotal = switch (discount) {
    NoDiscount() => 0,
    PercentDiscount(:final bp) => () {
        if (bp < 0 || bp > 10000) throw BillingError('bad_discount', 'percent must be 0–100');
        return mulDivHalfUp(subtotal, bp, 10000);
      }(),
    FlatDiscount(:final paise) => () {
        if (paise < 0) throw BillingError('bad_discount', 'flat discount cannot be negative');
        if (paise > subtotal) throw BillingError('discount_exceeds_subtotal', 'discount is larger than the subtotal');
        return paise;
      }(),
  };

  final shares = allocateDiscount(amounts, discountTotal);
  final out = <LineTotals>[];
  var cgst = 0, sgst = 0;
  for (var i = 0; i < lines.length; i++) {
    final taxable = amounts[i] - shares[i];
    final g = gstSplit(taxable, lines[i].taxRateBp);
    cgst += g.cgst;
    sgst += g.sgst;
    out.add(LineTotals(amountPaise: amounts[i], discountPaise: shares[i], taxablePaise: taxable, cgstPaise: g.cgst, sgstPaise: g.sgst));
  }
  final taxable = subtotal - discountTotal;
  final beforeRound = taxable + cgst + sgst + tipPaise;
  final roundOff = roundOffToRupee(beforeRound);
  return BillTotals(
    lines: out,
    subtotalPaise: subtotal,
    discountPaise: discountTotal,
    taxablePaise: taxable,
    cgstPaise: cgst,
    sgstPaise: sgst,
    tipPaise: tipPaise,
    roundOffPaise: roundOff,
    totalPaise: beforeRound + roundOff,
  );
}
