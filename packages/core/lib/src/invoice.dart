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

/// The restaurant's number as 4 hex digits (more past FFFF): cloud code R000123 → "007B". "0000" when not known yet.
String restaurantHexId(String? code) {
  final n = int.tryParse(RegExp(r'\d+').firstMatch(code ?? '')?.group(0) ?? '');
  return (n ?? 0).toRadixString(16).toUpperCase().padLeft(4, '0');
}

/// `<restaurant hex id>/<YYYYMMDD>/<HHmmssSSS>` at the billing time in IST, e.g. 007B/20261120/173045123.
String invoiceNoAt(String restaurantId, DateTime instant) {
  final t = instant.toUtc().add(const Duration(hours: 5, minutes: 30));
  String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
  return '$restaurantId/${t.year}${p(t.month)}${p(t.day)}/${p(t.hour)}${p(t.minute)}${p(t.second)}${p(t.millisecond, 3)}';
}
