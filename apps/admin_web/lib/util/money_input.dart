/// Parses rupees into integer paise without binary floating-point arithmetic.
int? parseRupees(String input) {
  final value = input.trim().replaceAll(',', '');
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value)) return null;
  final parts = value.split('.');
  final whole = int.tryParse(parts[0]);
  if (whole == null || whole > 10000000) return null;
  return whole * 100 + (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
}
