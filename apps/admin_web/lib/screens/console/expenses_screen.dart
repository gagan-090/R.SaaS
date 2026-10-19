import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../../api/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'dashboard_screen.dart' show rupees;

/// Expenses (plan feature "expenses"): rent, utilities, repairs and other non-stock spending, in paise. A mistake is
/// voided with a reason — never deleted — so the auditor sees both.
class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});
  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  Json? _data;
  Object? _error;
  bool _showVoided = false;

  ApiClient get _api => ref.read(apiProvider);
  bool get _canWrite {
    final a = ref.read(authProvider);
    return a is SignedIn && a.can('expense.write');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.expenses(includeVoided: _showVoided);
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _add() async {
    final ok = await showDialog<bool>(barrierDismissible: false, context: context, builder: (_) => _ExpenseEditor(api: _api, categories: (_data!['categories'] as List).cast<String>()));
    if (ok == true) {
      await _load();
      if (mounted) showDone(context, 'Expense recorded');
    }
  }

  Future<void> _void(Json e) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (d) => HPDialog(
        title: 'Void this expense?',
        actions: [SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(d)), DangerButton(key: const Key('confirm-void'), label: 'Void', onPressed: () => Navigator.pop(d, true))],
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${e['description']} · ${rupees(e['amountPaise'] as int)}. It stays in the records, marked void.', style: HPType.body(d.hp.muted)),
          const SizedBox(height: HPSpace.md),
          TextField(key: const Key('void-reason'), controller: reason, decoration: const InputDecoration(labelText: 'Reason (required)')),
        ]),
      ),
    );
    if (ok != true) return;
    try {
      await _api.voidExpense(e['id'] as String, reason.text.trim());
      await _load();
      if (mounted) showDone(context, 'Expense voided');
    } catch (err) {
      if (mounted) showError(context, err);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error is ApiException && (_error as ApiException).code == 'feature_not_in_plan') {
      return const PageFrame(title: 'Expenses', child: EmptyState(key: Key('expenses-locked'), icon: Icons.lock_outline_rounded, title: 'Expenses are not in your plan', message: 'Ask House Plating to add expense tracking to your plan.'));
    }
    if (_error != null) return ErrorState(message: '$_error', onRetry: _load);
    if (_data == null) return const LoadingState();
    final p = context.hp;
    final items = (_data!['items'] as List).cast<Json>();
    return PageFrame(
      title: 'Expenses',
      subtitle: 'Rent, utilities, repairs and other spending',
      actions: [if (_canWrite) PrimaryButton(key: const Key('add-expense'), label: 'Add expense', icon: Icons.add_rounded, height: 48, onPressed: _add)],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: HPSpace.md, runSpacing: HPSpace.md, children: [
          SizedBox(width: 240, child: KpiCard(key: const Key('expense-total'), label: 'Total', value: rupees(_data!['totalPaise'] as int), icon: Icons.payments_outlined)),
          for (final c in (_data!['byCategory'] as List).cast<Json>()) SizedBox(width: 200, child: KpiCard(label: '${c['category']}', value: rupees(c['amountPaise'] as int), icon: Icons.category_outlined)),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('show-voided'),
            onPressed: () {
              setState(() => _showVoided = !_showVoided);
              _load();
            },
            icon: Icon(_showVoided ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
            label: Text(_showVoided ? 'Hide voided' : 'Show voided'),
          ),
        ),
        if (items.isEmpty)
          const EmptyState(icon: Icons.receipt_outlined, title: 'No expenses yet', message: 'Record spending here to see it in reports.')
        else
          Card(
            child: Column(children: [
              for (final (i, e) in items.indexed) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  key: Key('expense-${e['description']}'),
                  title: Text('${e['description']}', style: HPType.label(e['voidedAt'] == null ? p.text : p.faint).copyWith(decoration: e['voidedAt'] == null ? null : TextDecoration.lineThrough)),
                  subtitle: Text(
                    ['${e['category']}', '${e['paidOn']}', '${e['paymentMode']}', 'by ${e['createdByName']}', if (e['reference'] != null) 'ref ${e['reference']}', if (e['voidReason'] != null) 'void: ${e['voidReason']}'].join(' · '),
                    style: HPType.body(p.muted),
                  ),
                  trailing: Wrap(spacing: HPSpace.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(rupees(e['amountPaise'] as int), style: HPType.label(p.text)),
                    if (_canWrite && e['voidedAt'] == null) IconButton(key: Key('void-${e['description']}'), tooltip: 'Void', icon: const Icon(Icons.block_rounded), onPressed: () => _void(e)),
                  ]),
                ),
              ],
            ]),
          ),
      ]),
    );
  }
}

class _ExpenseEditor extends StatefulWidget {
  const _ExpenseEditor({required this.api, required this.categories});
  final ApiClient api;
  final List<String> categories;
  @override
  State<_ExpenseEditor> createState() => _ExpenseEditorState();
}

class _ExpenseEditorState extends State<_ExpenseEditor> {
  final _desc = TextEditingController(), _amount = TextEditingController(), _ref = TextEditingController();
  final _date = TextEditingController(text: DateTime.now().toIso8601String().substring(0, 10));
  late String _cat = widget.categories.first;
  String _mode = 'upi';
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    final a = double.tryParse(_amount.text.trim().replaceAll(',', ''));
    if (_desc.text.trim().isEmpty) return setState(() => _error = 'Describe the expense');
    if (a == null || a <= 0) return setState(() => _error = 'Enter an amount in rupees');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(_date.text.trim())) return setState(() => _error = 'Date as YYYY-MM-DD');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.createExpense({
        'category': _cat, 'description': _desc.text.trim(), 'amountPaise': (a * 100).round(), 'paidOn': _date.text.trim(), 'paymentMode': _mode,
        if (_ref.text.trim().isNotEmpty) 'reference': _ref.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => HPDialog(
        title: 'Add an expense',
        actions: [SecondaryButton(label: 'Cancel', onPressed: _busy ? null : () => Navigator.pop(context)), PrimaryButton(key: const Key('save-expense'), label: 'Save', busy: _busy, height: 56, onPressed: _save)],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButtonFormField<String>(initialValue: _cat, isExpanded: true, decoration: const InputDecoration(labelText: 'Category'), items: [for (final c in widget.categories) DropdownMenuItem(value: c, child: Text(c))], onChanged: (v) => setState(() => _cat = v!)),
          const SizedBox(height: HPSpace.md),
          TextField(key: const Key('expense-desc'), controller: _desc, decoration: const InputDecoration(labelText: 'What for')),
          const SizedBox(height: HPSpace.md),
          Row(children: [
            Expanded(child: TextField(key: const Key('expense-amount'), controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '))),
            const SizedBox(width: HPSpace.sm),
            Expanded(child: TextField(controller: _date, decoration: const InputDecoration(labelText: 'Paid on (YYYY-MM-DD)'))),
          ]),
          const SizedBox(height: HPSpace.md),
          Wrap(spacing: HPSpace.xs, children: [for (final m in ['cash', 'upi', 'card', 'bank', 'other']) ChoiceChip(label: Text(m.toUpperCase()), selected: _mode == m, onSelected: (_) => setState(() => _mode = m))]),
          const SizedBox(height: HPSpace.md),
          TextField(controller: _ref, decoration: const InputDecoration(labelText: 'Bill / reference (optional)')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: HPSpace.sm), child: Text(_error!, key: const Key('expense-error'), style: HPType.body(context.hp.danger))),
        ]),
      );
}
