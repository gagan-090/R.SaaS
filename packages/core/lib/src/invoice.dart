/// Indian financial year (April–March) label for an instant, judged in IST: 2026-10-12 → "26-27".
String financialYear(DateTime instant) {
  final ist = instant.toUtc().add(const Duration(hours: 5, minutes: 30));
  final start = ist.month >= 4 ? ist.year : ist.year - 1;
  String two(int y) => (y % 100).toString().padLeft(2, '0');
  return '${two(start)}-${two(start + 1)}';
}

/// `<branch code>/<FY>/<6-digit sequence>`, e.g. BR01/26-27/000123.
String formatInvoiceNo(String branchCode, String fy, int seq) {
  if (seq <= 0 || seq > 999999) throw RangeError.range(seq, 1, 999999, 'seq');
  return '$branchCode/$fy/${seq.toString().padLeft(6, '0')}';
}
