import 'package:rsaas_hub/rsaas_hub.dart';
import 'package:test/test.dart';

void main() {
  test('uuidv7 is version 7, RFC variant, and strictly increasing within a millisecond', () {
    final t = DateTime.utc(2026, 10, 12);
    final ids = [for (var i = 0; i < 5000; i++) uuidv7(t)];
    expect(ids.toSet(), hasLength(5000));
    final sorted = [...ids]..sort();
    expect(sorted, ids);
    expect(ids.first[14], '7');
    expect('89ab'.contains(ids.first[19]), isTrue);
  });
}
