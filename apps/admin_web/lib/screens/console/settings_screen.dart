import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/labels.dart';
import 'branding_card.dart';
import 'staff_screen.dart' show MyPinDialog;

/// Restaurant settings: restaurant details (name, GSTIN, address, logo — on every bill — and the owner's POS PIN),
/// themes, the plan and taxes. Every section shows / hides from its title.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _name = TextEditingController(), _gstin = TextEditingController(), _address = TextEditingController();
  Json? _overview;
  List<Json>? _taxes;
  Object? _error;
  bool _busy = false;

  ApiClient get _api => ref.read(apiProvider);
  bool _can(String p) {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can(p);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([_api.overview(), _api.taxRules()]);
      if (!mounted) return;
      final o = r[0] as Json;
      final rest = o['restaurant'] as Json;
      _name.text = '${rest['name'] ?? ''}';
      _gstin.text = '${rest['gstin'] ?? ''}';
      _address.text = '${rest['address'] ?? ''}';
      setState(() {
        _overview = o;
        _taxes = (r[1] as List).cast<Json>();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _saveProfile() async {
    setState(() => _busy = true);
    try {
      await _api.updateProfile({
        'name': _name.text.trim(),
        'gstin': _gstin.text.trim().isEmpty ? null : _gstin.text.trim().toUpperCase(),
        'address': _address.text.trim().isEmpty ? null : _address.text.trim(),
      });
      if (mounted) showDone(context, 'Saved — new bills use these details');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addTax() async {
    var rate = 500;
    final ok = await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => HPDialog(
          title: 'Add a tax rate',
          actions: [SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(d)), PrimaryButton(label: 'Add', height: 56, onPressed: () => Navigator.pop(d, true))],
          child: Wrap(spacing: HPSpace.sm, children: [
            for (final r in [0, 500, 1200, 1800, 2800]) ChoiceChip(label: Text('${r ~/ 100}%'), selected: rate == r, onSelected: (_) => set(() => rate = r)),
          ]),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _api.createTaxRule('GST ${rate ~/ 100}%', rate);
      await _load();
      if (mounted) showDone(context, 'GST ${rate ~/ 100}% added');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// The signed-in person's own POS PIN (set or reset here; the POS asks for it).
  Widget get _myPin {
    final a = ref.read(authProvider) as SignedIn;
    final has = a.me['hasPin'] == true;
    return Column(key: const Key('my-pin-card'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('POS PIN', style: HPType.label(context.hp.text)),
      const SizedBox(height: HPSpace.sm),
      Text(has ? 'You sign in on the POS with your PIN. Reset it here.' : 'You have no POS PIN yet. The POS asks for it.', style: HPType.body(context.hp.muted)),
      const SizedBox(height: HPSpace.sm),
      Align(alignment: Alignment.centerLeft, child: SecondaryButton(key: const Key('set-my-pin'), label: has ? 'Reset PIN' : 'Set PIN', icon: Icons.pin_outlined, height: 48, onPressed: () async {
          final ok = await showDialog<bool>(barrierDismissible: false, context: context, builder: (_) => MyPinDialog(api: _api));
          if (ok == true) {
            await ref.read(authProvider.notifier).refresh();
            if (mounted) showDone(context, 'PIN saved — use it on the POS in about a minute');
          }
        })),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return loadErrorView(_error!, page: 'Settings', onRetry: _load);
    if (_overview == null) return const LoadingState();
    final p = context.hp;
    final lic = _overview!['license'] as Json;
    final edit = _can('restaurant.profile.manage');
    final narrow = isNarrowWeb(context);
    final signedIn = ref.read(authProvider);
    final hasPinRow = signedIn is SignedIn && signedIn.isRestaurant;
    final profile = SectionCard(
      title: 'Restaurant details',
      collapsible: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Name, GST and address print on every bill.', style: HPType.body(p.muted)),
        const SizedBox(height: HPSpace.md),
        TextField(key: const Key('profile-name'), controller: _name, enabled: edit, decoration: const InputDecoration(labelText: 'Restaurant name')),
        const SizedBox(height: HPSpace.md),
        TextField(key: const Key('profile-gstin'), controller: _gstin, enabled: edit, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'GST number (GSTIN)', hintText: '27AAAPA1234A1Z5')),
        const SizedBox(height: HPSpace.md),
        TextField(key: const Key('profile-address'), controller: _address, enabled: edit, maxLines: 2, decoration: const InputDecoration(labelText: 'Address')),
        if (edit) ...[const SizedBox(height: HPSpace.lg), Align(alignment: Alignment.centerRight, child: PrimaryButton(key: const Key('save-profile'), label: 'Save details', busy: _busy, height: 48, onPressed: _saveProfile))],
        const SizedBox(height: HPSpace.lg),
        const Divider(height: 1),
        const SizedBox(height: HPSpace.lg),
        const BrandingCard(part: BrandPart.logo),
        if (hasPinRow) ...[
          const SizedBox(height: HPSpace.lg),
          const Divider(height: 1),
          const SizedBox(height: HPSpace.lg),
          _myPin,
        ],
      ]),
    );
    final plan = SectionCard(
      title: 'Your plan',
      collapsible: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: HPSpace.md, runSpacing: HPSpace.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${lic['planName'] ?? '—'}', style: HPType.titleCard(p.text).copyWith(fontSize: 26)),
          StatusChip(label: statusLabel(lic['state']), tone: toneForStatus('${lic['state']}')),
        ]),
        const SizedBox(height: 4),
        Text(lic['endsAt'] == null ? 'No active license' : 'Renews ${shortDate(lic['endsAt'])}', style: HPType.body(p.muted)),
        const SizedBox(height: HPSpace.md),
        Text('YOUR PLAN INCLUDES', key: const Key('plan-includes'), style: HPType.overline(p.muted)),
        const SizedBox(height: HPSpace.sm),
        Wrap(spacing: HPSpace.xs, runSpacing: HPSpace.xs, children: [
          for (final f in (lic['features'] as List).cast<String>())
            Chip(avatar: Icon(Icons.check_rounded, size: 16, color: p.success), label: Text(featureLabel(f)), visualDensity: VisualDensity.compact),
        ]),
      ]),
    );
    final taxes = SectionCard(
      title: 'Taxes',
      collapsible: true,
      actions: [if (_can('menu.publish')) TextButton.icon(onPressed: _addTax, icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Add'))],
      child: _taxes!.isEmpty
          ? Text('No GST rates yet. Adding your first dish creates GST 5%.', style: HPType.body(p.muted))
          : Wrap(spacing: HPSpace.sm, runSpacing: HPSpace.sm, children: [
              for (final t in _taxes!) StatusChip(label: '${t['name']} · CGST ${(t['rateBp'] as int) / 200}% + SGST ${(t['rateBp'] as int) / 200}%'),
            ]),
    );
    return PageFrame(
      title: 'Settings',
      subtitle: 'Restaurant details, themes, plan and taxes · tap a title to show or hide it',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        narrow
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [profile, const SizedBox(height: HPSpace.lg), const BrandingCard(), const SizedBox(height: HPSpace.lg), plan, const SizedBox(height: HPSpace.lg), taxes])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [profile, const SizedBox(height: HPSpace.lg), const BrandingCard()])),
                const SizedBox(width: HPSpace.lg),
                Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [plan, const SizedBox(height: HPSpace.lg), taxes])),
              ]),
      ]),
    );
  }
}
