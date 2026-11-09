import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_pos/app.dart';
import 'package:rsaas_pos/state/app_state.dart';
import 'package:rsaas_pos/ui/responsive.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import 'fake_hub.dart';

/// Responsive sweep: every screen the POS has, at every representative viewport (phones, foldables, tablets,
/// laptops, ultrawide, phones in landscape), with long real-world names in the data. Any layout exception
/// (RenderFlex overflow, unbounded constraints, …) on any screen fails the test and names the screen.
const viewports = <(String, Size)>[
  ('compact mobile', Size(320, 568)),
  ('small mobile', Size(360, 640)),
  ('standard mobile', Size(390, 844)),
  ('large mobile', Size(430, 932)),
  ('folded phone', Size(360, 800)),
  ('foldable unfolded', Size(673, 841)),
  ('tablet portrait', Size(768, 1024)),
  ('tablet landscape', Size(1024, 768)),
  ('small laptop', Size(1280, 720)),
  ('laptop', Size(1366, 768)),
  ('macbook', Size(1440, 900)),
  ('large desktop', Size(1920, 1080)),
  ('ultrawide', Size(2560, 1080)),
  ('phone landscape', Size(844, 390)),
  ('small phone landscape', Size(640, 360)),
  ('compact mobile landscape', Size(568, 320)),
  ('large mobile landscape', Size(932, 430)),
  ('flip phone cover screen', Size(260, 512)),
  ('foldable unfolded landscape', Size(841, 673)),
  ('android tablet portrait', Size(800, 1280)),
  ('android tablet landscape', Size(1280, 800)),
  ('iPad Pro portrait', Size(1024, 1366)),
  ('portrait monitor', Size(1080, 1920)),
  ('ultrawide 21:9', Size(3440, 1440)),
];

const paired = DeviceSetup(hubBaseUrl: 'https://10.0.0.5:8443/hub/v1', deviceToken: 'dev-token', fingerprint: 'AA:BB');

/// Collects framework errors per screen instead of stopping at the first one.
class _Errors {
  final found = <String>[];
  String screen = 'start';
  FlutterExceptionHandler? _prev; // from foundation
  void listen() {
    _prev = FlutterError.onError;
    FlutterError.onError = (d) {
      final first = d.exceptionAsString().split('\n').first;
      // where in our code: the error-causing widget's creation site
      final where = RegExp(r'(lib/[\w/]+\.dart:\d+)').firstMatch(d.toString())?.group(1) ?? '';
      found.add('[$screen] $first $where');
      if (const bool.fromEnvironment('DEBUG_LAYOUT')) debugPrint(d.toString());
    };
  }

  void restore() => FlutterError.onError = _prev;

  /// Optional visual review: called with the name of the screen on display, just before the walk leaves it.
  Future<void> Function(String screen)? onLeave;
  var _shots = 0;
  Future<void> at(String next) async {
    if (onLeave != null) await onLeave!('${(_shots++).toString().padLeft(2, '0')}-$screen');
    screen = next;
  }
}

Future<FakeHubApi> _start(WidgetTester t, Size size, {DeviceSetup? setup = paired, double textScale = 1, List<DisplayFeature> features = const []}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  t.view.displayFeatures = features;
  t.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  final fake = FakeHubApi();
  // real-world data is longer than the demo: long names must wrap or ellipsize, never overflow
  fake.staffList.add({'id': 'u-long', 'name': 'Venkatanarasimharajuvaripeta Subramanian', 'roles': ['waiter', 'cashier'], 'pin': '4444'});
  fake.items.add({'id': 'i9', 'category_id': 'c1', 'name': 'Hyderabadi Dum Gosht Biryani with Mirchi ka Salan and Raita', 'price_paise': 1234500, 'rate_bp': 500, 'available': 1, 'is_veg': 0, 'plate_colors': null});
  for (var i = 3; i <= 14; i++) {
    fake.tables.add({'id': 't$i', 'floor_id': 'f1', 'name': '$i', 'seats': i.isEven ? 6 : 4, 'shape': 'square', 'pos_x': 60 * i, 'pos_y': 330, 'width': 50, 'height': 50, 'rotation': 0, 'manual_status': 'available'});
  }
  await t.pumpWidget(ProviderScope(overrides: [
    deviceStoreProvider.overrideWithValue(MemoryDeviceStore(setup)),
    hubApiFactoryProvider.overrideWithValue((_) => fake),
  ], child: const PosApp()));
  await t.pumpAndSettle();
  return fake;
}

Future<void> _tap(WidgetTester t, Finder f) async {
  // lazily built lists: scroll the innermost list until the target exists
  // (side-by-side layouts have several: try each, innermost first)
  final lists = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
  for (var l = lists.evaluate().length - 1; l >= 0 && f.evaluate().isEmpty; l--) {
    for (var i = 0; i < 12 && f.evaluate().isEmpty && lists.evaluate().length > l; i++) {
      await t.drag(lists.at(l), Offset(0, i < 6 ? -300 : 300), warnIfMissed: false);
      await t.pumpAndSettle();
    }
  }
  await t.ensureVisible(f.first);
  await t.pumpAndSettle();
  await t.tap(f.first);
  await t.pumpAndSettle();
}

Future<void> _back(WidgetTester t) async {
  await t.tap(find.byTooltip('Back').last);
  await t.pumpAndSettle();
}

Future<void> _closeSheetOrDialog(WidgetTester t) async {
  Navigator.of(t.element(find.byType(Scaffold).last)).pop();
  await t.pumpAndSettle();
}

Future<void> _signIn(WidgetTester t, String name, String pin) async {
  await _tap(t, find.byKey(Key('staff-$name')));
  for (final d in pin.split('')) {
    await _tap(t, find.byKey(Key('key-$d')));
  }
  await _tap(t, find.widgetWithText(PrimaryButton, 'Sign in'));
}

/// Walks every screen as the owner (who can see all of them), plus the chef's kitchen board and the IT admin home.
Future<void> _walk(WidgetTester t, _Errors e, Size size) async {
  final narrow = size.width < Breakpoints.twoPane;
  await e.at('staff login');
  await t.pumpAndSettle();
  await e.at('pin pad');
  await _signIn(t, 'Owner', '9999');

  await e.at('tables grid');
  await t.pumpAndSettle();
  await e.at('floor plan');
  await _tap(t, find.byKey(const Key('plan-toggle')));
  await _tap(t, find.byKey(const Key('plan-toggle')));

  await e.at('waiter picker sheet');
  await _tap(t, find.byKey(const Key('table-1')));
  await e.at('order screen');
  await _tap(t, find.byKey(const Key('waiter-Anita')));
  await _tap(t, find.byKey(const Key('dish-Butter Chicken')));
  await _tap(t, find.byKey(const Key('dish-Hyderabadi Dum Gosht Biryani with Mirchi ka Salan and Raita')));
  await e.at('size picker sheet');
  await _tap(t, find.byKey(const Key('dish-Cola')));
  await _tap(t, find.byKey(const Key('size-500 ml')));
  if (narrow && find.byKey(const Key('view-order')).evaluate().isNotEmpty) {
    // portrait phones: the order opens as a sheet (landscape phones show it beside the menu)
    await e.at('order sheet');
    await _tap(t, find.byKey(const Key('view-order')));
  }
  await e.at('note sheet');
  await _tap(t, find.text('Add note'));
  await _closeSheetOrDialog(t);
  await e.at('send KOT');
  await _tap(t, find.byKey(const Key('send-kot')));
  await e.at('reverse dialog');
  await _tap(t, find.byKey(const Key('reverse-Butter Chicken')));
  await _closeSheetOrDialog(t);
  await e.at('bill preview');
  await _tap(t, find.byKey(const Key('bill-pay')));
  await e.at('bill generated');
  await _tap(t, find.byKey(const Key('generate-bill')));
  await e.at('tip dialog');
  await _tap(t, find.text('Add tip'));
  await _closeSheetOrDialog(t);
  await e.at('payment');
  await _tap(t, find.text('Exact'));
  await _tap(t, find.textContaining('Pay CASH'));
  await e.at('paid');
  await t.pumpAndSettle();
  await _tap(t, find.text('Back to tables'));

  await e.at('kitchen');
  await _tap(t, find.byKey(const Key('nav-Kitchen')));
  await e.at('bills history');
  await _tap(t, find.byKey(const Key('nav-Bills')));
  await e.at('bill actions sheet');
  await _tap(t, find.byType(OrderCard));
  await e.at('adjust dialog');
  await _tap(t, find.byKey(const Key('bill-adjust')));
  await _closeSheetOrDialog(t);

  await e.at('more');
  await _tap(t, find.byKey(const Key('nav-More')));
  for (final (key, name) in [
    ('tips', 'tips'),
    ('printers', 'printers'),
    ('hub', 'hub & devices'),
    ('reports', 'reports'),
    ('menu', 'menu & stock'),
    ('staff', 'staff'),
    ('floors', 'floors'),
    ('settings', 'restaurant & license'),
  ]) {
    await e.at(name);
    await _tap(t, find.byKey(Key('more-$key')));
    await e.at('more'); // captures the page just opened, before going back
    await _back(t);
  }

  await e.at('switch user');
  await _tap(t, find.byKey(const Key('more-switch-user')));
  await e.at('chef kitchen');
  await _signIn(t, 'Kunal', '7777');
  await _tap(t, find.byKey(const Key('nav-More')));
  await _tap(t, find.byKey(const Key('more-switch-user')));
  await e.at('it admin setup');
  await _signIn(t, 'Imran', '3333');
  await e.at('end');
}

void main() {
  setUpAll(() => HPType.useGoogleFonts = false);

  for (final (name, size) in viewports) {
    final tag = '$name ${size.width.toInt()}×${size.height.toInt()}';

    testWidgets('[$tag] every screen lays out without overflow', (t) async {
      final e = _Errors()..listen();
      try {
        await _start(t, size);
        await _walk(t, e, size);
      } finally {
        e.restore();
      }
      expect(e.found, isEmpty, reason: e.found.toSet().join('\n'));
    });

    testWidgets('[$tag] device setup lays out without overflow', (t) async {
      final e = _Errors()..listen();
      try {
        e.screen = 'device setup';
        await _start(t, size, setup: null);
        e.screen = 'join a hub';
        if (find.text('Join a hub').evaluate().isNotEmpty) await _tap(t, find.text('Join a hub'));
        await _tap(t, find.text('Enter the address by hand'));
      } finally {
        e.restore();
      }
      expect(e.found, isEmpty, reason: e.found.toSet().join('\n'));
    });
  }


  // Opt-in visual review (not part of CI): every screen as PNGs at phone/tablet × portrait/landscape.
  //   flutter test test/responsive_test.dart --plain-name screenshots --update-goldens --dart-define=SHOTS=true --dart-define=SHOTS_DIR=/abs/dir
  const shots = bool.fromEnvironment('SHOTS');
  const shotsDir = String.fromEnvironment('SHOTS_DIR', defaultValue: '/tmp/rsaas-shots');
  for (final (tag, size) in const [('phone-P', Size(390, 844)), ('phone-L', Size(844, 390)), ('tablet-P', Size(800, 1280)), ('tablet-L', Size(1280, 800))]) {
    testWidgets('[$tag] screenshots', skip: !shots, (t) async {
      await t.runAsync(_loadFonts);
      final e = _Errors()
        ..onLeave = (name) async {
          await t.pumpAndSettle();
          await expectLater(find.byType(PosApp), matchesGoldenFile(Uri.file('$shotsDir/pos/$tag/${name.replaceAll(RegExp(r'[^\w-]+'), '-')}.png')));
        };
      await _start(t, size);
      await _walk(t, e, size);
    });
  }

  // accessibility: large system text on a small phone, a tablet and a laptop
  for (final (name, size) in [('small mobile', const Size(360, 640)), ('tablet portrait', const Size(768, 1024)), ('laptop', const Size(1366, 768))]) {
    testWidgets('[$name, text ×1.3] every screen lays out without overflow', (t) async {
      final e = _Errors()..listen();
      try {
        await _start(t, size, textScale: 1.3);
        await _walk(t, e, size);
      } finally {
        e.restore();
      }
      expect(e.found, isEmpty, reason: e.found.toSet().join('\n'));
    });
  }

  testWidgets('system text size is kept (and combined with restaurant branding), never replaced', (t) async {
    await _start(t, const Size(390, 844), textScale: 1.5);
    final ctx = t.element(find.byType(Scaffold).first);
    expect(MediaQuery.textScalerOf(ctx).scale(10), 15);
  });

  testWidgets('navigation adapts: bottom bar on phones, rail on tablets, labelled sidebar on desktops', (t) async {
    for (final (size, kind) in [(const Size(390, 844), 'bar'), (const Size(1024, 768), 'rail'), (const Size(1920, 1080), 'sidebar'), (const Size(844, 390), 'rail')]) {
      await _start(t, size);
      await _signIn(t, 'Owner', '9999');
      expect(find.byType(NavigationBar).evaluate().length, kind == 'bar' ? 1 : 0, reason: '$size');
      final rails = t.widgetList<NavigationRail>(find.byType(NavigationRail)).toList();
      expect(rails.length, kind == 'bar' ? 0 : 1, reason: '$size');
      if (rails.isNotEmpty) expect(rails.single.extended, kind == 'sidebar', reason: '$size');
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('book-style foldable: the order screen splits at the hinge, nothing underneath it', (t) async {
    const hinge = Rect.fromLTWH(1000, 0, 20, 900);
    await _start(t, const Size(2020, 900), features: const [DisplayFeature(bounds: hinge, type: DisplayFeatureType.hinge, state: DisplayFeatureState.postureFlat)]);
    await _signIn(t, 'Owner', '9999');
    await _tap(t, find.byKey(const Key('table-2')));
    await _tap(t, find.byKey(const Key('waiter-Anita')));
    final menu = t.getRect(find.byKey(const Key('menu-search')));
    final send = t.getRect(find.byKey(const Key('send-kot')));
    expect(menu.right, lessThanOrEqualTo(hinge.left));
    expect(send.left, greaterThanOrEqualTo(hinge.right));
  });

  test('size classes follow the breakpoints', () {
    expect(ScreenSize.of(320), ScreenSize.compact);
    expect(ScreenSize.of(390), ScreenSize.mobile);
    expect(ScreenSize.of(673), ScreenSize.largeMobile);
    expect(ScreenSize.of(768), ScreenSize.tablet);
    expect(ScreenSize.of(1024), ScreenSize.smallDesktop);
    expect(ScreenSize.of(1440), ScreenSize.desktop);
    expect(ScreenSize.of(2560), ScreenSize.largeDesktop);
    expect(columnsFor(320, minTileWidth: 140), 2);
    expect(columnsFor(1100, minTileWidth: 200, max: 4), 4);
    expect(sidePanelWidth(768), 320);
    expect(sidePanelWidth(2560), 460);
  });
}

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await l.load();
  }

  const kit = '../../packages/ui_kit/fonts';
  final sans = ['$kit/LiberationSans-Regular.ttf', '$kit/LiberationSans-Bold.ttf', '$kit/LiberationSans-Italic.ttf', '$kit/LiberationSans-BoldItalic.ttf'];
  await load('Arial', sans);
  await load('packages/rsaas_ui_kit/LiberationSans', sans);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/usr/local/share/flutter';
  await load('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
}
