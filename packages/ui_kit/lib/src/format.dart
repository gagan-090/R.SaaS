/// ₹ formatting for integer paise with Indian digit grouping (₹1,23,456.78). Display only.
String formatPaise(int paise, {bool symbol = true}) {
  final neg = paise < 0;
  final abs = paise.abs();
  final r = (abs ~/ 100).toString();
  final p = (abs % 100).toString().padLeft(2, '0');
  String g;
  if (r.length <= 3) {
    g = r;
  } else {
    final head = r.substring(0, r.length - 3);
    final parts = <String>[];
    for (var i = head.length; i > 0; i -= 2) {
      parts.insert(0, head.substring(i - 2 < 0 ? 0 : i - 2, i));
    }
    g = '${parts.join(',')},${r.substring(r.length - 3)}';
  }
  return '${neg ? '−' : ''}${symbol ? '₹' : ''}$g.$p';
}
