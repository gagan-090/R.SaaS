import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

void main() {
  Widget host(Brightness b, Widget child) => MaterialApp(theme: ThemeData(brightness: b), home: Scaffold(body: Center(child: child)));

  testWidgets('BhojMitra logo: bundled asset, plain on light, on a white plate on dark', (t) async {
    await t.pumpWidget(host(Brightness.light, const BhojMitraLogo(height: 50)));
    final img = t.widget<Image>(find.byType(Image));
    expect(img.image.toString(), contains('bhojmitra_logo.png'));
    expect(find.byType(Container), findsNothing);
    expect(t.getSize(find.byType(Image)).height, 50);

    await t.pumpWidget(host(Brightness.dark, const BhojMitraLogo(height: 50)));
    await t.pumpAndSettle(); // MaterialApp animates between themes
    final plate = t.widget<Container>(find.byKey(const Key('bhojmitra-logo')));
    expect((plate.decoration! as BoxDecoration).color, Colors.white);

    await t.pumpWidget(host(Brightness.dark, const BhojMitraLogo(height: 50, plate: false)));
    expect(find.byType(Container), findsNothing);
  });
}
