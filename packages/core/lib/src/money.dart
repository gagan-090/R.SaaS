/// Money as integer paise. There is no floating point anywhere in money paths.
final class Money implements Comparable<Money> {
  const Money(this.paise);
  const Money.rupees(int rupees) : paise = rupees * 100;

  static const zero = Money(0);

  final int paise;

  Money operator +(Money o) => Money(paise + o.paise);
  Money operator -(Money o) => Money(paise - o.paise);
  Money operator -() => Money(-paise);
  Money operator *(int qty) => Money(paise * qty);
  bool operator <(Money o) => paise < o.paise;
  bool operator <=(Money o) => paise <= o.paise;
  bool operator >(Money o) => paise > o.paise;
  bool operator >=(Money o) => paise >= o.paise;

  bool get isNegative => paise < 0;
  bool get isZero => paise == 0;

  @override
  int compareTo(Money other) => paise.compareTo(other.paise);

  @override
  bool operator ==(Object other) => other is Money && other.paise == paise;

  @override
  int get hashCode => paise.hashCode;

  /// Indian grouping: ₹1,23,456.78 (negative as −₹12.00).
  String format({bool symbol = true}) {
    final neg = paise < 0;
    final abs = paise.abs();
    final rupees = (abs ~/ 100).toString();
    final p = (abs % 100).toString().padLeft(2, '0');
    String grouped;
    if (rupees.length <= 3) {
      grouped = rupees;
    } else {
      final last3 = rupees.substring(rupees.length - 3);
      var rest = rupees.substring(0, rupees.length - 3);
      final parts = <String>[];
      while (rest.length > 2) {
        parts.insert(0, rest.substring(rest.length - 2));
        rest = rest.substring(0, rest.length - 2);
      }
      if (rest.isNotEmpty) parts.insert(0, rest);
      grouped = '${parts.join(',')},$last3';
    }
    return '${neg ? '−' : ''}${symbol ? '₹' : ''}$grouped.$p';
  }

  @override
  String toString() => format();
}

/// round(a × num / den) with halves rounded away from zero, using integers only.
int mulDivHalfUp(int a, int num, int den) {
  if (den <= 0) throw ArgumentError.value(den, 'den', 'must be positive');
  final n = a * num;
  final sign = n < 0 ? -1 : 1;
  final absN = n.abs();
  final q = absN ~/ den;
  final r = absN % den;
  return sign * (r * 2 >= den ? q + 1 : q);
}

/// floor(a × num / den) for non-negative inputs.
int mulDivFloor(int a, int num, int den) {
  if (a < 0 || num < 0 || den <= 0) throw ArgumentError('mulDivFloor expects non-negative inputs');
  return (a * num) ~/ den;
}
