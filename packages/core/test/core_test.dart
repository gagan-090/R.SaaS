import 'package:rsaas_core/rsaas_core.dart';
import 'package:test/test.dart';

void main() {
  group('Money', () {
    test('is integer paise with value semantics', () {
      expect(const Money(150) + const Money(250), const Money(400));
      expect(const Money(150) * 3, const Money(450));
      expect(const Money.rupees(2), const Money(200));
      expect(const Money(1) < const Money(2), isTrue);
    });
    test('formats with Indian grouping', () {
      expect(const Money(12345678).format(), '₹1,23,456.78');
      expect(const Money(5).format(), '₹0.05');
      expect(const Money(-120000).format(), '−₹1,200.00');
      expect(const Money(100000000).format(symbol: false), '10,00,000.00');
    });
  });

  group('integer rounding', () {
    test('mulDivHalfUp rounds halves away from zero', () {
      expect(mulDivHalfUp(10, 500, 10000), 1); // 0.5
      expect(mulDivHalfUp(9, 500, 10000), 0); // 0.45
      expect(mulDivHalfUp(-10, 500, 10000), -1);
      expect(() => mulDivHalfUp(1, 1, 0), throwsArgumentError);
    });
    test('gstSplit gives the odd paisa to CGST', () {
      expect(gstSplit(50, 1800), (cgst: 5, sgst: 4));
      expect(gstSplit(34000, 500), (cgst: 850, sgst: 850));
    });
    test('roundOffToRupee', () {
      expect(roundOffToRupee(1050), 50);
      expect(roundOffToRupee(1049), -49);
      expect(roundOffToRupee(1000), 0);
    });
    test('allocateDiscount never pushes a line negative', () {
      expect(allocateDiscount([3, 3, 1], 4), [1, 2, 1]);
      expect(allocateDiscount([1000, 1000, 1000], 100), [33, 33, 34]);
      expect(allocateDiscount([0, 0], 0), [0, 0]);
    });
  });

  group('validation', () {
    test('rejects bad inputs', () {
      expect(() => computeBill([const LineInput(pricePaise: 100, qty: 0, taxRateBp: 500)]), throwsA(isA<BillingError>()));
      expect(() => computeBill([const LineInput(pricePaise: 100, qty: 1, taxRateBp: 700)]), throwsA(isA<BillingError>()));
      expect(() => computeBill([const LineInput(pricePaise: 100, qty: 1, taxRateBp: 500)], tipPaise: -1), throwsA(isA<BillingError>()));
      expect(() => computeBill([const LineInput(pricePaise: 100, qty: 1, taxRateBp: 500)], discount: const PercentDiscount(10001)), throwsA(isA<BillingError>()));
    });
    test('GSTIN and reason', () {
      expect(isValidGstin('27AAAPA1234A1Z5'), isTrue);
      expect(isValidGstin('27AAAPA1234A1Z'), isFalse);
      expect(isValidReason('  '), isFalse);
      expect(isValidReason('Guest changed mind'), isTrue);
    });
  });

  group('invoice numbers', () {
    test('financial year runs April–March in IST', () {
      expect(financialYear(DateTime.utc(2026, 10, 12)), '26-27');
      expect(financialYear(DateTime.utc(2027, 3, 31, 18, 29)), '26-27'); // 23:59 IST on 31 Mar
      expect(financialYear(DateTime.utc(2027, 3, 31, 18, 30)), '27-28'); // 00:00 IST on 1 Apr
    });
    test('format is BR01/26-27/000123', () {
      expect(formatInvoiceNo('BR01', '26-27', 123), 'BR01/26-27/000123');
      expect(() => formatInvoiceNo('BR01', '26-27', 0), throwsRangeError);
    });
  });
}
