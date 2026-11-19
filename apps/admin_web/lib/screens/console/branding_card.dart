import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../util/image_prep.dart';
import '../../widgets/common.dart';

/// Ready-made colours; any other colour can be typed as #RRGGBB.
const brandPresets = <(String, String)>[
  ('#6B1F2A', 'House wine'), ('#C62828', 'Chilli red'), ('#E65100', 'Tandoor orange'), ('#F0A93B', 'Saffron'),
  ('#2E7D32', 'Mint green'), ('#00796B', 'Teal'), ('#1A73E8', 'Blue'), ('#3949AB', 'Indigo'), ('#6A1B9A', 'Plum'), ('#212121', 'Charcoal'),
];

/// One text style choice: text size and heading weight go together (small text → light headings, large → extra bold).
const textStyles = <(String size, String weight, String label)>[
  ('compact', 'regular', 'Small'), ('standard', 'bold', 'Normal'), ('large', 'heavy', 'Large'),
];

/// Which part of the restaurant's look a [BrandingCard] shows: the logo (under Restaurant details) or the theme.
enum BrandPart { logo, theme }

/// Settings → Themes: colour (any of 16.7 million) and text style for the console and the POS; with [BrandPart.logo]
/// only the logo, for Restaurant details (plan feature "branding"). Without the feature the card says how to get it;
/// the API refuses saves anyway.
class BrandingCard extends ConsumerStatefulWidget {
  const BrandingCard({super.key, this.part = BrandPart.theme});
  final BrandPart part;
  @override
  ConsumerState<BrandingCard> createState() => _BrandingCardState();
}

class _BrandingCardState extends ConsumerState<BrandingCard> {
  Json? _data;
  Object? _error;
  final _hex = TextEditingController();
  String _textSize = 'standard', _weight = 'bold', _case = 'normal';
  String? _logoId;
  Uint8List? _logoBytes; // just uploaded, shown before the network copy loads
  bool _busy = false, _logoBusy = false;
  String? _hexError;

  ApiClient get _api => ref.read(apiProvider);
  bool get _canEdit {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can('restaurant.profile.manage');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.branding();
      if (!mounted) return;
      final s = (d['saved'] as Json?) ?? (d['defaults'] as Json);
      setState(() {
        _data = d;
        _hex.text = '${s['color']}';
        _textSize = '${s['textSize']}';
        _weight = '${s['headingWeight']}';
        _case = '${s['headingCase']}';
        _logoId = s['logoImageId'] as String?;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  HPBrand? get _draft => HPBrand.fromJson({'color': _hex.text.trim(), 'textSize': _textSize, 'headingWeight': _weight, 'headingCase': _case, 'logoImageId': _logoId});

  Future<void> _save() async {
    if (_draft == null) return setState(() => _hexError = 'Use a colour like #1A73E8');
    setState(() {
      _busy = true;
      _hexError = null;
    });
    try {
      await _api.setBranding({'color': _draft!.hex, 'textSize': _textSize, 'headingWeight': _weight, 'headingCase': _case});
      ref.read(brandRefreshProvider.notifier).state++;
      if (mounted) showDone(context, 'Theme saved — the POS picks it up within a minute');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadLogo() async {
    final raw = await pickPhoto();
    if (raw == null) return;
    setState(() => _logoBusy = true);
    try {
      final img = prepareLogo(raw);
      final r = await _api.setLogo(img.contentType, img.base64);
      setState(() {
        _logoId = r['logoImageId'] as String?;
        _logoBytes = img.bytes;
      });
      ref.read(brandRefreshProvider.notifier).state++;
      if (mounted) showDone(context, 'Logo saved');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  Future<void> _removeLogo() async {
    setState(() => _logoBusy = true);
    try {
      await _api.removeLogo();
      setState(() {
        _logoId = null;
        _logoBytes = null;
      });
      ref.read(brandRefreshProvider.notifier).state++;
      if (mounted) showDone(context, 'Logo removed');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  /// Any colour: hue, saturation and brightness sliders (16.7 million colours) with a live swatch, or a typed #RRGGBB.
  Future<void> _pickCustom() async {
    final start = _draft?.color ?? context.hp.accent;
    var hsv = HSVColor.fromColor(start);
    final picked = await showConsoleDialog<Color>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, set) {
        final c = hsv.toColor();
        Widget slider(String key, String label, double value, double max, List<Color> track, ValueChanged<double> on) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(label, style: HPType.label(d.hp.muted)),
          Container(
            height: 10,
            margin: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), gradient: LinearGradient(colors: track)),
          ),
          Slider(key: Key(key), value: value, max: max, onChanged: (v) => set(() => on(v))),
        ]);
        return HPDialog(
          title: 'Custom colour',
          actions: [
            SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(d)),
            PrimaryButton(key: const Key('use-custom-colour'), label: 'Use colour', height: 56, onPressed: () => Navigator.pop(d, c)),
          ],
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              key: const Key('custom-colour-swatch'),
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(14)),
              child: Text(_hexOf(c), style: HPType.label(HPBrand.onColor(c))),
            ),
            const SizedBox(height: HPSpace.md),
            slider('hue', 'Colour', hsv.hue, 360, [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor()], (v) => hsv = hsv.withHue(v)),
            slider('saturation', 'Strength', hsv.saturation, 1, [HSVColor.fromAHSV(1, hsv.hue, 0, hsv.value).toColor(), HSVColor.fromAHSV(1, hsv.hue, 1, hsv.value).toColor()], (v) => hsv = hsv.withSaturation(v)),
            slider('brightness', 'Brightness', hsv.value, 1, [Colors.black, HSVColor.fromAHSV(1, hsv.hue, hsv.saturation, 1).toColor()], (v) => hsv = hsv.withValue(v)),
          ]),
        );
      }),
    );
    if (picked != null && mounted) {
      setState(() {
        _hex.text = _hexOf(picked);
        _hexError = null;
      });
    }
  }

  static String _hexOf(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  Widget _locked(HPPalette p) => Row(key: const Key('branding-locked'), crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lock_outline_rounded, color: p.muted),
        const SizedBox(width: HPSpace.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Custom branding is not in your plan', style: HPType.titleCard(p.text)),
            const SizedBox(height: 4),
            Text('Ask BhojMitra to switch on "Custom branding" for your plan. Then you can add your logo, colour and text style, '
                'and they appear on this console and on every POS device.', style: HPType.body(p.muted)),
          ]),
        ),
      ]);

  Widget _logo(HPPalette p) {
    final edit = _canEdit;
    return Column(key: const Key('logo-section'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Logo', style: HPType.label(p.text)),
      const SizedBox(height: HPSpace.sm),
      Wrap(spacing: HPSpace.md, runSpacing: HPSpace.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Container(
          width: 140,
          height: 72,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(HPSpace.sm),
          decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(12), border: Border.all(color: p.line)),
          child: _logoBytes != null
              ? Image.memory(_logoBytes!, fit: BoxFit.contain)
              : _logoId != null
                  ? Image.network(_api.mediaUrl(_logoId!), fit: BoxFit.contain, errorBuilder: (_, _, _) => Icon(Icons.broken_image_outlined, color: p.muted))
                  : Text('No logo', style: HPType.body(p.muted)),
        ),
        if (edit) ...[
          SecondaryButton(key: const Key('upload-logo'), label: _logoId == null ? 'Upload logo' : 'Change', icon: Icons.upload_rounded, onPressed: _logoBusy ? null : _uploadLogo),
          if (_logoId != null) TextButton(onPressed: _logoBusy ? null : _removeLogo, child: const Text('Remove')),
        ],
      ]),
      const SizedBox(height: 4),
      Text('PNG with a transparent background looks best. Shown on bills, in the sidebar and on the POS.', style: HPType.body(p.muted).copyWith(fontSize: 12)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    final logoOnly = widget.part == BrandPart.logo;
    if (logoOnly) {
      if (_error != null) return ErrorState(message: '$_error', onRetry: _load);
      if (_data == null) return const SkeletonBox(height: 90);
      return _data!['enabled'] == true
          ? _logo(p)
          : Row(key: const Key('logo-locked'), children: [
              Icon(Icons.lock_outline_rounded, size: 18, color: p.muted),
              const SizedBox(width: HPSpace.sm),
              Expanded(child: Text('Logo: needs "Custom branding" in your plan', style: HPType.body(p.muted))),
            ]);
    }
    if (_error != null) return SectionCard(title: 'Themes', collapsible: true, child: ErrorState(message: '$_error', onRetry: _load));
    if (_data == null) return const SectionCard(title: 'Themes', collapsible: true, child: SkeletonBox(height: 120));
    if (_data!['enabled'] != true) {
      return SectionCard(
        title: 'Themes',
        collapsible: true,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _locked(p)),
        ]),
      );
    }
    final edit = _canEdit;
    final draft = _draft;
    final swatch = draft?.color ?? p.accent;
    Widget label(String s) => Padding(padding: const EdgeInsets.only(top: HPSpace.lg, bottom: HPSpace.sm), child: Text(s, style: HPType.label(p.text)));
    Widget seg(String key, String value, List<(String, String)> options, ValueChanged<String> on) => SegmentedButton<String>(
          key: Key(key),
          showSelectedIcon: false,
          segments: [for (final (v, l) in options) ButtonSegment(value: v, label: Text(l))],
          selected: {value},
          onSelectionChanged: edit ? (s) => setState(() => on(s.first)) : null,
        );

    final controls = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Colour', style: HPType.label(p.text)),
      const SizedBox(height: HPSpace.sm),
      Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
        for (final (hex, name) in brandPresets)
          Tooltip(
            message: name,
            child: InkWell(
              key: Key('swatch-$hex'),
              customBorder: const CircleBorder(),
              onTap: edit ? () => setState(() => _hex.text = hex) : null,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: HPBrand.fromJson({'color': hex})!.color,
                  shape: BoxShape.circle,
                  border: Border.all(color: _hex.text.toUpperCase() == hex ? p.text : p.line, width: _hex.text.toUpperCase() == hex ? 3 : 1),
                ),
              ),
            ),
          ),
      ]),
      const SizedBox(height: HPSpace.md),
      SizedBox(
        width: 220,
        child: TextField(
          key: const Key('brand-hex'),
          controller: _hex,
          enabled: edit,
          onChanged: (_) => setState(() => _hexError = null),
          decoration: InputDecoration(
            labelText: 'Or type a colour',
            hintText: '#1A73E8',
            errorText: _hexError,
            prefixIcon: Padding(padding: const EdgeInsets.all(14), child: CircleAvatar(radius: 9, backgroundColor: swatch)),
          ),
        ),
      ),
      if (edit) ...[
        const SizedBox(height: HPSpace.sm),
        SecondaryButton(key: const Key('custom-colour'), label: 'Custom colour', icon: Icons.palette_outlined, height: 48, onPressed: _pickCustom),
      ],
      label('Text style'),
      // one choice: text size and heading weight together (small text, light headings … large text, extra bold)
      seg('brand-text-style', textStyles.firstWhere((t) => t.$1 == _textSize, orElse: () => textStyles[1]).$1,
          [for (final t in textStyles) (t.$1, t.$3)], (v) {
        _textSize = v;
        _weight = textStyles.firstWhere((t) => t.$1 == v).$2;
      }),
      label('Headings'),
      seg('brand-case', _case, const [('normal', 'Aa'), ('upper', 'AA')], (v) => _case = v),
      if (edit) ...[
        const SizedBox(height: HPSpace.x2),
        PrimaryButton(key: const Key('save-branding'), label: 'Save theme', busy: _busy, height: 48, onPressed: _save),
      ],
    ]);

    final preview = _Preview(brand: draft, name: ref.watch(restaurantLookProvider).valueOrNull?.name ?? 'Your restaurant', logo: _logoBytes, logoUrl: _logoId == null ? null : _api.mediaUrl(_logoId!));
    return SectionCard(
      title: 'Themes',
      collapsible: true,
      child: LayoutBuilder(
        builder: (c, box) => box.maxWidth < 760
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [controls, const SizedBox(height: HPSpace.x2), preview])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: controls), const SizedBox(width: HPSpace.x2), SizedBox(width: 340, child: preview)]),
      ),
    );
  }
}

/// How the choices look before saving: a mini POS screen in the draft colour and text style.
class _Preview extends StatelessWidget {
  const _Preview({required this.brand, required this.name, this.logo, this.logoUrl});
  final HPBrand? brand;
  final String name;
  final Uint8List? logo;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    final base = context.hp;
    final p = brand?.apply(base) ?? base;
    final scale = brand?.textScale ?? 1;
    final upper = brand?.headingCase == 'upper';
    final heading = HPType.titleCard(p.text).copyWith(fontWeight: brand?.weight ?? FontWeight.w700, fontSize: 18 * scale);
    final fill = brand?.color ?? HPColors.amber;
    final onFill = HPBrand.onColor(fill);
    return Container(
      key: const Key('brand-preview'),
      padding: const EdgeInsets.all(HPSpace.lg),
      decoration: BoxDecoration(color: p.ground, borderRadius: BorderRadius.circular(HPRadius.card), border: Border.all(color: p.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('PREVIEW', style: HPType.overline(p.muted)),
        const SizedBox(height: HPSpace.md),
        Row(children: [
          if (logo != null || logoUrl != null) ...[
            SizedBox(height: 32, width: 64, child: logo != null ? Image.memory(logo!, fit: BoxFit.contain) : Image.network(logoUrl!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox())),
            const SizedBox(width: HPSpace.sm),
          ],
          Expanded(child: Text(upper ? name.toUpperCase() : name, style: heading, overflow: TextOverflow.ellipsis)),
        ]),
        const SizedBox(height: HPSpace.md),
        Container(
          padding: const EdgeInsets.all(HPSpace.md),
          decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.line)),
          child: Row(children: [
            CircleAvatar(radius: 16, backgroundColor: fill, child: Text('4', style: HPType.label(onFill).copyWith(fontSize: 14 * scale))),
            const SizedBox(width: HPSpace.sm),
            Expanded(child: Text('Table 4 · 3 items', style: HPType.body(p.text).copyWith(fontSize: 14 * scale))),
            Text('₹420', style: HPType.label(p.accentInk).copyWith(fontSize: 15 * scale)),
          ]),
        ),
        const SizedBox(height: HPSpace.md),
        Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(HPRadius.button)),
          child: Text(upper ? 'SEND TO KITCHEN' : 'Send to kitchen', style: HPType.label(onFill).copyWith(fontSize: 15 * scale)),
        ),
      ]),
    );
  }
}
