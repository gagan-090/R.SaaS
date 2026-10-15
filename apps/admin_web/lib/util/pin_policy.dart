/// PIN rules, shown before saving; the server enforces the same (apps/api/src/staff/pin-policy.ts).
String? pinProblem(String p) {
  if (!RegExp(r'^\d{6,8}$').hasMatch(p)) return 'PIN must be 6 to 8 digits';
  if (RegExp(r'^(\d)\1+$').hasMatch(p)) return 'PIN cannot be the same digit repeated';
  final d = p.split('').map(int.parse).toList();
  bool run(int step) => [for (var i = 1; i < d.length; i++) d[i] == (d[i - 1] + step + 10) % 10].every((x) => x);
  if (run(1) || run(-1)) return 'PIN cannot be a run of digits like 123456';
  return null;
}

