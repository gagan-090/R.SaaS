import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:rsaas_hub/rsaas_hub.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// A LAN thermal printer stand-in: accepts raw TCP on a loopback port and records each job's bytes.
class FakePrinter {
  FakePrinter._(this._server) {
    _server.listen((s) {
      final buf = BytesBuilder();
      s.listen(buf.add, onDone: () {
        jobs.add(buf.toBytes());
        s.destroy();
        _job.add(null);
      });
    });
  }
  final ServerSocket _server;
  final jobs = <Uint8List>[];
  final _job = StreamController<void>.broadcast();
  int get port => _server.port;

  static Future<FakePrinter> start() async => FakePrinter._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  /// Bytes arrive after the client closes; wait until [n] jobs have landed.
  Future<void> waitFor(int n) async {
    while (jobs.length < n) {
      await _job.stream.first.timeout(const Duration(seconds: 5));
    }
  }

  /// The printable text of a job (ESC/GS command bytes removed).
  static String text(Uint8List b) {
    final out = StringBuffer();
    for (var i = 0; i < b.length; i++) {
      final c = b[i];
      if (c == 0x1b && b[i + 1] == 0x40) {
        i += 1;
      } else if (c == 0x1b || c == 0x1d) {
        i += 2;
      } else {
        out.writeCharCode(c);
      }
    }
    return out.toString().trimRight();
  }

  Future<void> close() => _server.close();
}

const _goldenDir = 'test/golden_receipts';

/// Snapshot check; `UPDATE_GOLDENS=1 dart test` rewrites the files (review the diff before committing).
void expectSnapshot(String name, String actual) {
  final f = File('$_goldenDir/$name.txt');
  if (Platform.environment['UPDATE_GOLDENS'] == '1') {
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('$actual\n');
  }
  expect(f.existsSync(), isTrue, reason: 'missing snapshot ${f.path}; run with UPDATE_GOLDENS=1');
  expect('$actual\n', f.readAsStringSync(), reason: 'receipt layout changed: ${f.path}');
}

void main() {
  late Harness h;
  late String cashier;
  late String owner;
  late FakePrinter printer;
  setUp(() async {
    h = await Harness.start();
    cashier = await h.login(Harness.cashier);
    owner = await h.login(Harness.owner);
    printer = await FakePrinter.start();
  });
  tearDown(() async {
    await printer.close();
    await h.close();
  });

  Future<http.Response> rawPost(String path, String session, [Object? body]) =>
      http.post(Uri.parse('${h.base}$path'), headers: h.headers(session: session), body: jsonEncode(body ?? {}));

  /// Dine-in on table 1 for Anita: 2 butter chicken (5%), 3 naan with a note (5%), 1 lassi (12%), 10% discount,
  /// KOT sent, bill generated, ₹30 tip, paid by UPI ₹300 + cash with change.
  Future<(String orderId, String billId, String ticketId)> fullService() async {
    final o = (await h.post('/orders', session: cashier, body: {'type': 'dine_in', 'tableId': Harness.t1, 'waiterId': Harness.waiter})).json;
    final id = o['id']! as String;
    await h.post('/orders/$id/lines', session: cashier, body: {
      'lines': [
        {'menuItemId': Harness.butterChicken, 'qty': 2},
        {'menuItemId': Harness.naan, 'qty': 3, 'notes': 'extra butter, less garlic'},
        {'menuItemId': Harness.lassi, 'qty': 1},
      ],
    });
    final kot = await h.post('/orders/$id/kot', session: cashier);
    expect(kot.status, 201, reason: '$kot');
    final bill = (await h.post('/orders/$id/bill', session: owner, body: {'discount': {'type': 'percent', 'bp': 1000}})).json;
    final billId = bill['id']! as String;
    await h.post('/bills/$billId/tip', session: cashier, body: {'amountPaise': 3000});
    await h.post('/bills/$billId/payments', session: cashier, idem: 'print-test-0001', body: {'mode': 'upi', 'amountPaise': 30000});
    final total = (await h.hub.db.selectOne('SELECT total_paise FROM bills WHERE id = ?', [billId]))!['total_paise']! as int;
    final cash = await h.post('/bills/$billId/payments', session: cashier, idem: 'print-test-0002', body: {'mode': 'cash', 'tenderedPaise': 100000});
    expect(cash.json['changePaise'], 100000 - (total - 30000));
    return (id, billId, kot.json['ticketId']! as String);
  }

  group('receipt layout (snapshots)', () {
    test('80 mm customer bill: header, GST by rate, discount, tip, round-off, split payment', () async {
      final (_, billId, _) = await fullService();
      final r = await h.hub.billReceiptFor(billId);
      expect(r.toText().split('\n').every((l) => l.length <= 48), isTrue);
      expectSnapshot('bill_80mm', r.toText());
    });

    test('80 mm KOT: table, waiter, time, qty + notes, no prices; REPRINT marker', () async {
      final (_, _, ticketId) = await fullService();
      final first = (await h.hub.kotReceiptFor(ticketId)).toText();
      expect(first, isNot(contains('Rs')));
      expect(first, isNot(contains('340')));
      expectSnapshot('kot_80mm', first);
      expect((await h.hub.kotReceiptFor(ticketId, reprint: true)).toText().split('\n').first.trim(), '*** REPRINT ***');
    });

    test('58 mm duplicate bill fits 32 columns', () async {
      final (_, billId, _) = await fullService();
      final r = await h.hub.billReceiptFor(billId, duplicate: true, width: 32);
      expect(r.toText().split('\n').every((l) => l.length <= 32), isTrue);
      expectSnapshot('bill_58mm_duplicate', r.toText());
    });

    test('long names wrap; non-ASCII never reaches the printer', () {
      final b = ReceiptBuilder(48)
        ..columns(['Paneer Tikka Masala — Chef’s Special with Extra Gravy', '1', '₹1.00', '1.00'], [22, 5, 10, 11])
        ..pair('Total ₹', '−0.30');
      final text = b.build().toText();
      expect(text.split('\n'), hasLength(4));
      expect(text.runes.every((c) => c < 0x80), isTrue);
      expect(text, contains('Total Rs'));
      expect(text, endsWith('-0.30'));
    });
  });

  group('ESC/POS over TCP 9100 (fake printer)', () {
    test('KOT auto-prints to the kitchen printer; the bill prints once, then as DUPLICATE (audited)', () async {
      final put = await http.put(Uri.parse('${h.base}/printers'), headers: h.headers(session: cashier),
          body: jsonEncode({'bill': {'host': '127.0.0.1', 'port': printer.port}}));
      expect(put.statusCode, 403); // a cashier cannot change printers
      final ok = await http.put(Uri.parse('${h.base}/printers'), headers: h.headers(session: owner),
          body: jsonEncode({'bill': {'host': '127.0.0.1', 'port': printer.port, 'widthChars': 48}}));
      expect(ok.statusCode, 200, reason: ok.body);

      final (_, billId, ticketId) = await fullService();
      await printer.waitFor(1); // KOT (no kitchen printer → the bill printer takes it)
      final kotBytes = printer.jobs[0];
      expect(kotBytes.sublist(0, 2), [0x1b, 0x40]); // ESC @
      expect(kotBytes.sublist(kotBytes.length - 3), [0x1d, 0x56, 0x01]); // GS V 1 partial cut
      expect(kotBytes.every((b) => b < 0x80), isTrue);
      expect(FakePrinter.text(kotBytes), contains('KOT #1'));

      final p1 = await rawPost('/bills/$billId/print', cashier);
      expect(p1.statusCode, 200, reason: p1.body);
      expect(jsonDecode(p1.body), containsPair('status', 'printed'));
      expect(jsonDecode(p1.body), containsPair('copyNo', 1));
      final p2 = await rawPost('/bills/$billId/print', cashier);
      expect(jsonDecode(p2.body), containsPair('reprint', true));
      await printer.waitFor(3);
      expect(FakePrinter.text(printer.jobs[1]), isNot(contains('DUPLICATE')));
      expect(FakePrinter.text(printer.jobs[2]), contains('*** DUPLICATE ***'));
      expect(FakePrinter.text(printer.jobs[1]), contains('Invoice: BR01/26-27/000001'));

      final kotReprint = await rawPost('/kot/$ticketId/print', cashier);
      expect(jsonDecode(kotReprint.body), containsPair('copyNo', 2));
      await printer.waitFor(4);
      expect(FakePrinter.text(printer.jobs[3]), contains('*** REPRINT ***'));

      final audit = await h.hub.db.query("SELECT action FROM audit_events WHERE action LIKE '%.reprinted' ORDER BY at, id");
      expect(audit.map((r) => r['action']), ['bill.reprinted', 'kot.reprinted']);
      expect((await rawPost('/bills/$billId/print', await h.login(Harness.waiter))).statusCode, 403);
    });

    test('test print reaches the printer; an unreachable printer is a 502, never silent', () async {
      await http.put(Uri.parse('${h.base}/printers'), headers: h.headers(session: owner),
          body: jsonEncode({'bill': {'host': '127.0.0.1', 'port': printer.port}, 'kot': {'host': '127.0.0.1', 'port': 1}}));
      expect((await h.post('/printers/bill/test', session: owner)).json, {'status': 'printed', 'target': 'bill'});
      await printer.waitFor(1);
      expect(FakePrinter.text(printer.jobs.single), contains('TEST PRINT'));
      final bad = await h.post('/printers/kot/test', session: owner);
      expect(bad.status, 502);
      expect(bad.code, 'printer_unreachable');
      expect((await h.put('/printers', session: owner, body: {'kot': {'host': '', 'port': 9100}})).code, 'bad_printer');
      expect((await h.put('/printers', session: owner, body: {'kot': {'host': 'x', 'widthChars': 40}})).code, 'bad_printer');
    });
  });

  group('PDF fallback', () {
    test('no printer → the print request returns a PDF; the copy is still counted', () async {
      final (_, billId, _) = await fullService();
      final r = await rawPost('/bills/$billId/print', cashier);
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], 'application/pdf');
      expect(r.headers['x-print-status'], 'pdf');
      expect(r.headers['x-print-error'], 'no_printer');
      expect(utf8.decode(r.bodyBytes.sublist(0, 5), allowMalformed: true), '%PDF-');
      final again = await rawPost('/bills/$billId/print', cashier);
      expect(again.headers['x-print-copy'], '2');
    });

    test('printer unreachable → PDF with printer_unreachable; asking for a PDF skips the printer', () async {
      await h.put('/printers', session: owner, body: {'bill': {'host': '127.0.0.1', 'port': 1}});
      final (_, billId, _) = await fullService();
      final r = await rawPost('/bills/$billId/print', cashier);
      expect(r.headers['x-print-error'], 'printer_unreachable');
      expect(r.headers['content-type'], 'application/pdf');
      final pdf = await rawPost('/bills/$billId/print', cashier, {'pdf': true});
      expect(pdf.headers['x-print-status'], 'pdf');
      expect(pdf.headers.containsKey('x-print-error'), isFalse);
      final jobs = await h.hub.db.query("SELECT status, error FROM print_jobs WHERE doc_type = 'bill' ORDER BY copy_no");
      expect(jobs.map((j) => j['status']), ['pdf', 'pdf']);
      expect(jobs.first['error'], isNotNull);
    });
  });
}
