import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:rsaas_core/rsaas_core.dart';

/// Thermal receipts (Build Spec §13): one layout model rendered two ways — ESC/POS bytes for an
/// 80 mm (48 chars) or 58 mm (32 chars) printer on TCP 9100, and a PDF fallback with the same text.

enum ReceiptAlign { left, center, right }

class ReceiptLine {
  const ReceiptLine(this.text, {this.align = ReceiptAlign.left, this.bold = false, this.big = false});
  final String text;
  final ReceiptAlign align;
  final bool bold;

  /// Double height + width (half as many characters fit on the line).
  final bool big;
}

class Receipt {
  Receipt(this.width, this.lines);
  final int width;
  final List<ReceiptLine> lines;

  /// Plain-text rendering (what the paper shows, without styling) — used for snapshot tests and the PDF.
  String toText() => lines.map((l) {
        final w = l.big ? width ~/ 2 : width;
        return switch (l.align) {
          ReceiptAlign.left => l.text,
          ReceiptAlign.center => l.text.padLeft((w + l.text.length) ~/ 2),
          ReceiptAlign.right => l.text.padLeft(w),
        }.trimRight();
      }).join('\n');
}

/// Printer code pages are ASCII-safe only; anything else is mapped or replaced so the paper never shows mojibake.
String receiptAscii(String s) {
  const map = {'₹': 'Rs', '—': '-', '−': '-', '–': '-', '’': "'", '‘': "'", '“': '"', '”': '"', '…': '...', '×': 'x', '·': '-'};
  final b = StringBuffer();
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    b.write(map[c] ?? (r >= 0x20 && r < 0x7f ? c : '?'));
  }
  return b.toString();
}

class ReceiptBuilder {
  ReceiptBuilder(this.width) {
    if (width != 48 && width != 32) throw ArgumentError('width must be 48 (80 mm) or 32 (58 mm)');
  }
  final int width;
  final _lines = <ReceiptLine>[];

  void text(String s, {ReceiptAlign align = ReceiptAlign.left, bool bold = false, bool big = false}) {
    final w = big ? width ~/ 2 : width;
    for (final part in _wrap(receiptAscii(s), w)) {
      _lines.add(ReceiptLine(part, align: align, bold: bold, big: big));
    }
  }

  void center(String s, {bool bold = false, bool big = false}) => text(s, align: ReceiptAlign.center, bold: bold, big: big);

  /// Label on the left, value flush right. If both do not fit on one line, the label gets its own line(s)
  /// and the value goes flush right underneath — numbers are never split.
  void pair(String label, String value, {bool bold = false}) {
    label = receiptAscii(label);
    value = receiptAscii(value);
    if (label.length + 1 + value.length <= width) {
      _lines.add(ReceiptLine(label.padRight(width - value.length) + value, bold: bold));
      return;
    }
    for (final part in _wrap(label, width)) {
      _lines.add(ReceiptLine(part, bold: bold));
    }
    _lines.add(ReceiptLine(value.padLeft(width), bold: bold));
  }

  /// Fixed columns: text left-aligned in the first, the rest right-aligned. Overflowing first-column text wraps.
  void columns(List<String> cells, List<int> widths, {bool bold = false}) {
    assert(widths.fold(0, (a, b) => a + b) == width);
    final first = _wrap(receiptAscii(cells.first), widths.first - 1);
    final rest = [
      for (var i = 1; i < cells.length; i++)
        if (receiptAscii(cells[i]).length >= widths[i]) throw ArgumentError('"${cells[i]}" does not fit a ${widths[i]}-wide column') else receiptAscii(cells[i]).padLeft(widths[i]),
    ].join();
    _lines.add(ReceiptLine(first.first.padRight(widths.first) + rest, bold: bold));
    for (final more in first.skip(1)) {
      _lines.add(ReceiptLine('  $more', bold: bold));
    }
  }

  void rule([String ch = '-']) => _lines.add(ReceiptLine(ch * width));
  void blank() => _lines.add(const ReceiptLine(''));

  Receipt build() => Receipt(width, List.unmodifiable(_lines));

  static List<String> _wrap(String s, int w) {
    if (s.length <= w) return [s];
    final out = <String>[];
    var line = '';
    for (final word in s.split(' ')) {
      var wd = word;
      while (wd.length > w) {
        if (line.isNotEmpty) {
          out.add(line);
          line = '';
        }
        out.add(wd.substring(0, w));
        wd = wd.substring(w);
      }
      if (line.isEmpty) {
        line = wd;
      } else if (line.length + 1 + wd.length <= w) {
        line = '$line $wd';
      } else {
        out.add(line);
        line = wd;
      }
    }
    if (line.isNotEmpty || out.isEmpty) out.add(line);
    return out;
  }
}

String _rs(int paise) => Money(paise).format(symbol: false);

/// "2.5%" from basis points.
String _pct(int bp) {
  final whole = bp ~/ 100;
  final frac = bp % 100;
  if (frac == 0) return '$whole%';
  return '$whole.${frac.toString().padLeft(2, '0').replaceAll(RegExp(r'0$'), '')}%';
}

class KotPrintLine {
  const KotPrintLine({required this.name, required this.qty, this.notes});
  final String name;
  final int qty;
  final String? notes;
}

/// Kitchen order ticket: table or takeaway no., waiter, time, items with qty and notes, REPRINT marker; no prices.
Receipt kotReceipt({
  required int width,
  required int kotNo,
  required String where,
  String? waiter,
  required String time,
  required List<KotPrintLine> lines,
  bool reprint = false,
}) {
  final b = ReceiptBuilder(width);
  if (reprint) b.center('*** REPRINT ***', bold: true);
  b.center('KOT #$kotNo', bold: true, big: true);
  b.center(where, bold: true, big: true);
  b.pair('Waiter: ${waiter ?? '-'}', time);
  b.rule();
  for (final l in lines) {
    b.text('${l.qty.toString().padLeft(3)} x ${l.name}', bold: true);
    if (l.notes != null && l.notes!.trim().isNotEmpty) b.text('      > ${l.notes!.trim()}');
  }
  b.rule();
  b.center('${lines.fold(0, (s, l) => s + l.qty)} item(s)');
  return b.build();
}

class BillPrintLine {
  const BillPrintLine({required this.name, required this.qty, required this.ratePaise, required this.amountPaise, required this.taxRateBp, required this.cgstPaise, required this.sgstPaise});
  final String name;
  final int qty;
  final int ratePaise;
  final int amountPaise;
  final int taxRateBp;
  final int cgstPaise;
  final int sgstPaise;
}

class PaymentPrintLine {
  const PaymentPrintLine({required this.mode, required this.amountPaise, this.tenderedPaise, this.changePaise = 0});
  final String mode;
  final int amountPaise;
  final int? tenderedPaise;
  final int changePaise;
}

/// Customer tax invoice: restaurant name/address/GSTIN, invoice no. + date, table, waiter, lines, subtotal, discount,
/// CGST/SGST with rates, tip, round-off, total, payment modes, "Duplicate" on reprints.
Receipt billReceipt({
  required int width,
  required String restaurantName,
  String? address,
  String? gstin,
  required String invoiceNo,
  required String dateTime,
  required String where,
  String? waiter,
  required List<BillPrintLine> lines,
  required int subtotalPaise,
  required int discountPaise,
  required int tipPaise,
  required int roundOffPaise,
  required int totalPaise,
  List<PaymentPrintLine> payments = const [],
  bool duplicate = false,
}) {
  final b = ReceiptBuilder(width);
  if (duplicate) b.center('*** DUPLICATE ***', bold: true);
  b.center(restaurantName, bold: true, big: true);
  if (address != null && address.isNotEmpty) b.center(address);
  if (gstin != null && gstin.isNotEmpty) b.center('GSTIN: $gstin');
  b.center('TAX INVOICE', bold: true);
  b.rule();
  b.pair('Invoice: $invoiceNo', dateTime);
  b.pair(where, 'Waiter: ${waiter ?? '-'}');
  b.rule();
  if (width == 48) {
    const cols = [22, 5, 10, 11];
    b.columns(['Item', 'Qty', 'Rate', 'Amount'], cols, bold: true);
    for (final l in lines) {
      b.columns([l.name, '${l.qty}', _rs(l.ratePaise), _rs(l.amountPaise)], cols);
    }
  } else {
    // 58 mm: name on its own line, then "qty x rate" and the amount — four columns do not fit 32 characters.
    b.pair('Item', 'Amount', bold: true);
    for (final l in lines) {
      b.text(l.name);
      b.pair('  ${l.qty} x ${_rs(l.ratePaise)}', _rs(l.amountPaise));
    }
  }
  b.rule();
  b.pair('Subtotal', _rs(subtotalPaise));
  if (discountPaise != 0) b.pair('Discount', '-${_rs(discountPaise)}');
  final byRate = <int, (int, int)>{};
  for (final l in lines) {
    final (c, s) = byRate[l.taxRateBp] ?? (0, 0);
    byRate[l.taxRateBp] = (c + l.cgstPaise, s + l.sgstPaise);
  }
  for (final rate in byRate.keys.toList()..sort()) {
    final (c, s) = byRate[rate]!;
    b.pair('CGST @ ${_pct(rate ~/ 2)}', _rs(c));
    b.pair('SGST @ ${_pct(rate - rate ~/ 2)}', _rs(s));
  }
  if (tipPaise != 0) b.pair('Tip', _rs(tipPaise));
  if (roundOffPaise != 0) b.pair('Round off', roundOffPaise > 0 ? '+${_rs(roundOffPaise)}' : _rs(roundOffPaise));
  b.rule('=');
  b.pair('TOTAL  Rs', _rs(totalPaise), bold: true);
  b.rule('=');
  for (final p in payments) {
    b.pair('Paid by ${p.mode.toUpperCase()}', _rs(p.amountPaise));
    if (p.tenderedPaise != null && p.changePaise != 0) {
      b.pair('  Tendered', _rs(p.tenderedPaise!));
      b.pair('  Change', _rs(p.changePaise));
    }
  }
  final paid = payments.fold(0, (s, p) => s + p.amountPaise);
  if (paid < totalPaise) b.pair('Balance due', _rs(totalPaise - paid), bold: true);
  b.blank();
  b.center('Thank you! Visit again.');
  return b.build();
}

/// Test page for the IT admin printer screen (T3).
Receipt testReceipt({required int width, required String printerLabel, required String time}) {
  final b = ReceiptBuilder(width)
    ..center('TEST PRINT', bold: true, big: true)
    ..center(printerLabel)
    ..center(time)
    ..rule();
  b.text('0123456789' * (width ~/ 10) + '0123456789'.substring(0, width % 10));
  b.columns(['Left column', 'Right'], [width - 10, 10]);
  b.rule();
  b.center('If this line is centred, the paper width is set correctly.');
  return b.build();
}

/// ESC/POS command stream: initialise, then each line with alignment / emphasis / size, feed and partial cut.
Uint8List encodeEscPos(Receipt r, {bool cut = true}) {
  const esc = 0x1b, gs = 0x1d;
  final out = BytesBuilder()..add([esc, 0x40]); // ESC @ initialise
  for (final l in r.lines) {
    out.add([esc, 0x61, l.align.index]); // ESC a n: 0 left, 1 centre, 2 right
    out.add([esc, 0x45, l.bold ? 1 : 0]); // ESC E n: emphasis
    out.add([gs, 0x21, l.big ? 0x11 : 0x00]); // GS ! n: double width + height
    out.add(ascii.encode(receiptAscii(l.text)));
    out.addByte(0x0a);
  }
  out.add([esc, 0x61, 0, esc, 0x45, 0, gs, 0x21, 0]);
  out.add([esc, 0x64, 4]); // ESC d 4: feed 4 lines past the cutter
  if (cut) out.add([gs, 0x56, 0x01]); // GS V 1: partial cut
  return out.toBytes();
}

/// PDF fallback with the same text in a monospace font on an 80 mm (or 58 mm) roll.
Future<Uint8List> receiptPdf(Receipt r, {String? title}) async {
  final doc = pw.Document(title: title, creator: 'rsaas_hub');
  final paper = r.width == 48 ? PdfPageFormat.roll80 : PdfPageFormat.roll57;
  final usable = paper.width - 2 * 4 * PdfPageFormat.mm;
  final size = usable / (r.width * 0.6); // Courier advance width = 0.6 em
  final font = pw.Font.courier();
  final bold = pw.Font.courierBold();
  doc.addPage(pw.Page(
    pageFormat: paper.copyWith(marginLeft: 4 * PdfPageFormat.mm, marginRight: 4 * PdfPageFormat.mm, marginTop: 4 * PdfPageFormat.mm, marginBottom: 4 * PdfPageFormat.mm),
    build: (_) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        for (final l in r.lines)
          pw.Text(
            l.text.isEmpty ? ' ' : l.text,
            textAlign: switch (l.align) {
              ReceiptAlign.left => pw.TextAlign.left,
              ReceiptAlign.center => pw.TextAlign.center,
              ReceiptAlign.right => pw.TextAlign.right,
            },
            style: pw.TextStyle(font: l.bold ? bold : font, fontSize: l.big ? size * 2 : size),
          ),
      ],
    ),
  ));
  return doc.save();
}

/// Where a print job goes. Production uses [TcpPrinterSender]; tests use a fake TCP printer.
abstract class PrinterSender {
  Future<void> send(Uint8List bytes);
}

/// Raw ESC/POS over TCP (port 9100 by default, the "JetDirect" convention every LAN thermal printer speaks).
class TcpPrinterSender implements PrinterSender {
  TcpPrinterSender(this.host, {this.port = 9100, this.timeout = const Duration(seconds: 5)});
  final String host;
  final int port;
  final Duration timeout;

  @override
  Future<void> send(Uint8List bytes) async {
    final s = await Socket.connect(host, port, timeout: timeout);
    try {
      s.add(bytes);
      await s.flush().timeout(timeout);
    } finally {
      await s.close().timeout(timeout, onTimeout: () => s.destroy());
    }
  }
}

/// Per-branch printer settings (T3), stored on the hub.
class PrinterSettings {
  const PrinterSettings({required this.host, this.port = 9100, this.widthChars = 48});
  final String host;
  final int port;
  final int widthChars;

  static PrinterSettings? fromJson(Object? j) {
    if (j is! Map) return null;
    final host = j['host'];
    final port = j['port'] ?? 9100;
    final width = j['widthChars'] ?? 48;
    if (host is! String || host.trim().isEmpty || port is! int || port < 1 || port > 65535 || (width != 48 && width != 32)) return null;
    return PrinterSettings(host: host.trim(), port: port, widthChars: width as int);
  }

  Map<String, Object?> toJson() => {'host': host, 'port': port, 'widthChars': widthChars};
}
