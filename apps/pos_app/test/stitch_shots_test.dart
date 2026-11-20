// Opt-in design pack: every POS screen for each role, 5 views per screen (phone light, phone dark, phone full length,
// tablet landscape, tablet portrait), with real fonts and icons — for redesign work (e.g. Google Stitch).
//   flutter test test/stitch_shots_test.dart --update-goldens --dart-define=SHOTS=true --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=FONT_DIR=/abs/fonts   (HelveticaNeue-{Regular,Medium,Bold,Italic,BoldItalic}.ttf, has the ₹ sign)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_pos/app.dart';
import 'package:rsaas_pos/state/app_state.dart' show themeModeProvider;
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pos_test.dart' show nav, navTabs, orderTable1, signIn, start, switchUser;

const enabled = bool.fromEnvironment('SHOTS');
const outDir = String.fromEnvironment('SHOTS_DIR', defaultValue: '/tmp/rsaas-stitch');
const fontDir = String.fromEnvironment('FONT_DIR');

/// The 5 views of every screen: (file prefix, size, dark).
const views = <(String, Size, bool)>[
  ('1-phone-light', Size(390, 844), false),
  ('2-phone-dark', Size(390, 844), true),
  ('3-phone-full-page', Size(390, 1800), false),
  ('4-tablet-landscape', Size(1280, 800), false),
  ('5-tablet-portrait', Size(800, 1280), false),
];

String slug(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');

Future<void> loadDesignFonts() async {
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await l.load();
  }

  final sans = fontDir.isEmpty
      ? [for (final w in ['Regular', 'Bold', 'Italic', 'BoldItalic']) '../../packages/ui_kit/fonts/LiberationSans-$w.ttf']
      : [for (final w in ['Regular', 'Medium', 'Bold', 'Italic', 'BoldItalic']) '$fontDir/HelveticaNeue-$w.ttf'];
  for (final fam in ['Arial', 'Roboto', 'packages/rsaas_ui_kit/LiberationSans']) {
    await load(fam, sans);
  }
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/usr/local/share/flutter';
  await load('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
}

void main() {
  setUpAll(() async {
    HPType.useGoogleFonts = false;
    await loadDesignFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (view, size, dark) in views) {
    testWidgets('[$view] POS, every role', skip: !enabled, (t) async {
      final narrow = size.width < 700;
      Future<void> shot(String role, String screen) async {
        debugPrint('SHOT $role / $screen');
        await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));
        await expectLater(find.byType(PosApp), matchesGoldenFile(Uri.file('$outDir/pos-app/$role/${slug(screen)}/$view.png')));
      }

      Future<void> tabs(String role) async {
        for (final (i, tab) in navTabs(t).indexed) {
          await nav(t, tab);
          await shot(role, '${(i + 1).toString().padLeft(2, '0')} $tab');
        }
      }

      Future<void> signOut() async {
        if (find.byKey(const Key('user-menu')).evaluate().isEmpty) await nav(t, navTabs(t).first);
        await switchUser(t);
      }

      Future<void> closeSheet() async {
        if (narrow && find.byType(BottomSheet).evaluate().isNotEmpty) {
          await t.tapAt(const Offset(10, 10));
          await t.pumpAndSettle();
        }
      }

      final hub = await start(t, size: size, brightness: dark ? Brightness.dark : Brightness.light);
      if (dark) {
        await ProviderScope.containerOf(t.element(find.byType(PosApp))).read(themeModeProvider.notifier).set(ThemeMode.dark);
        await t.pumpAndSettle();
      }
      await shot('sign-in', '01 Who is working');
      await t.tap(find.byKey(const Key('staff-Ravi')));
      await t.pumpAndSettle();
      await shot('sign-in', '02 PIN pad');
      for (final d in '1234'.split('')) {
        await t.tap(find.byKey(Key('key-$d')));
      }
      await t.pump();
      await t.tap(find.widgetWithText(PrimaryButton, 'Sign in'));
      await t.pumpAndSettle();

      // Cashier: takes orders, sends KOTs, bills and takes payment
      await orderTable1(t, narrow: narrow);
      await shot('cashier', '10 Order with KOT sent');
      await t.ensureVisible(find.byKey(const Key('bill-pay')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('bill-pay')));
      await shot('cashier', '11 Bill preview');
      await t.ensureVisible(find.byKey(const Key('generate-bill')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('generate-bill')));
      await shot('cashier', '12 Payment');
      await signOut();
      await signIn(t, 'Ravi', '1234');
      await tabs('cashier');
      await signOut();

      // Waiter: opens their tables and sends KOTs; cannot bill
      await signIn(t, 'Anita', '5555');
      await t.tap(find.byKey(const Key('table-2')));
      await t.pumpAndSettle();
      await shot('waiter', '10 Menu - taking an order');
      await t.tap(find.byKey(const Key('dish-Garlic Naan')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('dish-Butter Chicken')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key(narrow ? 'cart-send-kot' : 'send-kot')));
      await t.pumpAndSettle();
      if (narrow) {
        await t.tap(find.byKey(const Key('view-order')));
        await t.pumpAndSettle();
      }
      await shot('waiter', '11 Order sent to kitchen');
      await closeSheet();
      await signOut();
      await signIn(t, 'Anita', '5555');
      await tabs('waiter');
      await signOut();

      // Chef: the kitchen queue (two KOTs waiting)
      await signIn(t, 'Kunal', '7777');
      await tabs('chef');
      await nav(t, 'Kitchen');
      await t.ensureVisible(find.byKey(const Key('ticket-1-preparing')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('ticket-1-preparing')));
      await shot('chef', '10 Kitchen - cooking');
      await signOut();

      // Owner: everything on one device, plus the owner console shortcuts
      await signIn(t, 'Owner', '9999');
      await tabs('owner');
      await signOut();

      // Restaurant admin (IT): devices, printers, setup
      await signIn(t, 'Imran', '3333');
      await tabs('it-admin');
      await signOut();
      expect(hub.tickets, isNotEmpty);
    });
  }
}
