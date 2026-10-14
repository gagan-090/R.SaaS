import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

import '../hub/hub_api.dart';
import '../state/app_state.dart';
import '../ui/common.dart';
import '../ui/shell.dart';

// ============================================================================
// 1. SALES & BUSINESS REPORTS SCREEN
// ============================================================================

class ReportsDashboardScreen extends ConsumerStatefulWidget {
  const ReportsDashboardScreen({super.key});

  @override
  ConsumerState<ReportsDashboardScreen> createState() => _ReportsDashboardScreenState();
}

class _ReportsDashboardScreenState extends ConsumerState<ReportsDashboardScreen> {
  DateTime _date = DateTime.now();
  int _reloadKey = 0;

  bool get _isToday {
    final now = DateTime.now();
    return _date.year == now.year && _date.month == now.month && _date.day == now.day;
  }

  void _setToday() {
    setState(() {
      _date = DateTime.now();
      _reloadKey++;
    });
  }

  void _setYesterday() {
    setState(() {
      _date = DateTime.now().subtract(const Duration(days: 1));
      _reloadKey++;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        _reloadKey++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(hubApiProvider);
    if (api == null) return const Scaffold(body: LoadingState());
    final p = context.hp;

    return Scaffold(
      body: Column(
        children: [
          PosTopBar(
            title: 'Sales & Reports',
            subtitle: _isToday ? 'Today · ${clock12(DateTime.now().toIso8601String())}' : '${_date.day}/${_date.month}/${_date.year}',
            actions: [
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => setState(() => _reloadKey++),
              ),
            ],
          ),
          Expanded(
            child: FutureBuilder<List<Json>>(
              key: ValueKey('bills-$_reloadKey-${_date.toIso8601String().substring(0, 10)}'),
              future: api.bills(_date),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return ErrorState(
                    message: errText(snapshot.error!),
                    onRetry: () => setState(() => _reloadKey++),
                  );
                }
                if (!snapshot.hasData) return const LoadingState(label: 'Loading sales data…');

                final bills = snapshot.data!;
                return _buildDashboardContent(context, p, bills);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardContent(BuildContext context, HPPalette p, List<Json> bills) {
    // Compute aggregations
    int totalSalesPaise = 0;
    int taxPaise = 0;
    int discountPaise = 0;
    int tipPaise = 0;
    int cashPaise = 0;
    int upiPaise = 0;
    int cardPaise = 0;
    int dineInCount = 0;
    int takeawayCount = 0;

    for (final b in bills) {
      final total = (b['total_paise'] as int?) ?? 0;
      totalSalesPaise += total;
      taxPaise += (b['tax_paise'] as int?) ?? 0;
      discountPaise += (b['discount_paise'] as int?) ?? 0;
      tipPaise += (b['tip_paise'] as int?) ?? 0;

      if (b['table_name'] != null) {
        dineInCount++;
      } else {
        takeawayCount++;
      }

      final payments = (b['payments'] as List?)?.cast<Json>() ?? const [];
      for (final py in payments) {
        final amt = (py['amount_paise'] as int?) ?? 0;
        final mode = '${py['mode']}'.toLowerCase();
        if (mode.contains('upi')) {
          upiPaise += amt;
        } else if (mode.contains('card')) {
          cardPaise += amt;
        } else {
          cashPaise += amt;
        }
      }
    }

    final billCount = bills.length;
    final avgBillPaise = billCount > 0 ? (totalSalesPaise ~/ billCount) : 0;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ListView(
          padding: const EdgeInsets.all(HPSpace.lg),
          children: [
            // Date Filter Bar
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: HPSpace.md, vertical: HPSpace.sm),
                child: Row(
                  children: [
                    FilterChip(
                      selected: _isToday,
                      label: const Text('Today'),
                      onSelected: (_) => _setToday(),
                    ),
                    const SizedBox(width: HPSpace.sm),
                    FilterChip(
                      selected: !_isToday,
                      label: Text('${_date.day}/${_date.month}/${_date.year}'),
                      avatar: const Icon(Icons.calendar_today_rounded, size: 16),
                      onSelected: (_) => _pickDate(),
                    ),
                    const Spacer(),
                    if (!_isToday)
                      TextButton.icon(
                        icon: const Icon(Icons.history_toggle_off_rounded, size: 18),
                        label: const Text('Yesterday'),
                        onPressed: _setYesterday,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HPSpace.lg),

            // Top KPIs
            Wrap(
              spacing: HPSpace.md,
              runSpacing: HPSpace.md,
              children: [
                SizedBox(
                  width: 180,
                  child: KpiCard(
                    key: const Key('kpi-sales'),
                    label: 'Gross Sales',
                    value: rupees(totalSalesPaise),
                    caption: '$billCount bill(s)',
                    icon: Icons.currency_rupee_rounded,
                    tone: HPTone.saffron,
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: KpiCard(
                    key: const Key('kpi-avg'),
                    label: 'Average Bill',
                    value: rupees(avgBillPaise),
                    caption: 'Per customer',
                    icon: Icons.analytics_outlined,
                    tone: HPTone.success,
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: KpiCard(
                    key: const Key('kpi-tax'),
                    label: 'Taxes (GST)',
                    value: rupees(taxPaise),
                    caption: 'Collected',
                    icon: Icons.account_balance_outlined,
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: KpiCard(
                    key: const Key('kpi-tips'),
                    label: 'Tips',
                    value: rupees(tipPaise),
                    caption: 'Staff gratuity',
                    icon: Icons.volunteer_activism_rounded,
                    tone: HPTone.pending,
                  ),
                ),
              ],
            ),
            const SizedBox(height: HPSpace.lg),

            // Payment Modes Breakdown
            Card(
              child: Padding(
                padding: const EdgeInsets.all(HPSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Payment Methods', style: HPType.titleCard(p.text)),
                    const SizedBox(height: HPSpace.sm),
                    Text('Settled payments breakdown for this period', style: HPType.body(p.muted)),
                    const SizedBox(height: HPSpace.md),
                    Row(
                      children: [
                        Expanded(
                          child: _PaymentTile(
                            title: 'Cash',
                            amount: rupees(cashPaise),
                            icon: Icons.payments_outlined,
                            color: HPColors.saffron,
                          ),
                        ),
                        const SizedBox(width: HPSpace.sm),
                        Expanded(
                          child: _PaymentTile(
                            title: 'UPI',
                            amount: rupees(upiPaise),
                            icon: Icons.qr_code_2_rounded,
                            color: HPColors.cardamom,
                          ),
                        ),
                        const SizedBox(width: HPSpace.sm),
                        Expanded(
                          child: _PaymentTile(
                            title: 'Card',
                            amount: rupees(cardPaise),
                            icon: Icons.credit_card_rounded,
                            color: HPColors.chili,
                          ),
                        ),
                      ],
                    ),
                    if (discountPaise > 0) ...[
                      const SizedBox(height: HPSpace.md),
                      Divider(color: p.line),
                      const SizedBox(height: HPSpace.xs),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Total Discounts Applied', style: HPType.body(p.muted)),
                          Text(rupees(discountPaise), style: HPType.label(p.danger)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: HPSpace.lg),

            // Order Channels
            Card(
              child: Padding(
                padding: const EdgeInsets.all(HPSpace.lg),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Dine-In', style: HPType.titleCard(p.text)),
                          Text('$dineInCount bill(s)', style: HPType.body(p.muted)),
                        ],
                      ),
                    ),
                    Container(height: 40, width: 1, color: p.line),
                    const SizedBox(width: HPSpace.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Takeaway', style: HPType.titleCard(p.text)),
                          Text('$takeawayCount bill(s)', style: HPType.body(p.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HPSpace.lg),

            // Recent Bills
            Text('Bills (${bills.length})', style: HPType.titleCard(p.text)),
            const SizedBox(height: HPSpace.sm),
            if (bills.isEmpty)
              const EmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'No bills for this date',
                message: 'Bills completed on this date will appear here.',
              )
            else
              for (final b in bills.take(15))
                Card(
                  margin: const EdgeInsets.only(bottom: HPSpace.sm),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: p.raised,
                      child: Icon(Icons.receipt_rounded, color: p.accentInk, size: 20),
                    ),
                    title: Text(
                      'Bill #${b['bill_no'] ?? b['id']} · ${b['table_name'] != null ? 'Table ${b['table_name']}' : 'Takeaway'}',
                      style: HPType.label(p.text),
                    ),
                    subtitle: Text(
                      '${b['waiter_name'] ?? 'Counter'} · ${b['closed_at'] == null ? 'Open' : clock12(b['closed_at'])}',
                      style: HPType.body(p.muted).copyWith(fontSize: 12),
                    ),
                    trailing: Text(
                      rupees((b['total_paise'] as int?) ?? 0),
                      style: HPType.titleCard(p.text),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _PaymentTile extends StatelessWidget {
  const _PaymentTile({required this.title, required this.amount, required this.icon, required this.color});
  final String title;
  final String amount;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = context.hp;
    return Container(
      padding: const EdgeInsets.all(HPSpace.md),
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: HPSpace.xs),
              Text(title, style: HPType.label(p.muted)),
            ],
          ),
          const SizedBox(height: HPSpace.xs),
          Text(amount, style: HPType.titleCard(p.text)),
        ],
      ),
    );
  }
}

// ============================================================================
// 2. MENU & ITEM AVAILABILITY (86 TOGGLE) SCREEN
// ============================================================================

class MenuManagementScreen extends ConsumerStatefulWidget {
  const MenuManagementScreen({super.key});

  @override
  ConsumerState<MenuManagementScreen> createState() => _MenuManagementScreenState();
}

class _MenuManagementScreenState extends ConsumerState<MenuManagementScreen> {
  String? _selectedCategory;
  String _searchQuery = '';
  final _searchCtl = TextEditingController();
  int _reloadKey = 0;
  final Set<String> _toggling = {};

  Future<void> _toggleAvailability(String itemId, String itemName) async {
    final api = ref.read(hubApiProvider);
    if (api == null) return;
    setState(() => _toggling.add(itemId));
    try {
      final res = await api.toggleItemAvailability(itemId);
      final isAvail = res['available'] == true;
      if (mounted) {
        toast(context, '$itemName is now ${isAvail ? "In Stock" : "86 / Out of Stock"}');
      }
    } catch (e) {
      if (mounted) toast(context, errText(e), error: true);
    } finally {
      if (mounted) {
        setState(() {
          _toggling.remove(itemId);
          _reloadKey++;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(hubApiProvider);
    if (api == null) return const Scaffold(body: LoadingState());
    final p = context.hp;

    return Scaffold(
      body: Column(
        children: [
          PosTopBar(
            title: 'Menu & Stock',
            subtitle: 'Dish availability & 86 management',
            actions: [
              IconButton(
                tooltip: 'Refresh menu',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => setState(() => _reloadKey++),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HPSpace.lg, vertical: HPSpace.sm),
            child: TextField(
              controller: _searchCtl,
              decoration: InputDecoration(
                hintText: 'Search dishes by name or code…',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _searchCtl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
              ),
              onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: FutureBuilder<Json>(
              key: ValueKey('menu-$_reloadKey'),
              future: api.menu(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return ErrorState(
                    message: errText(snapshot.error!),
                    onRetry: () => setState(() => _reloadKey++),
                  );
                }
                if (!snapshot.hasData) return const LoadingState(label: 'Loading menu…');

                final menu = snapshot.data!;
                final categories = (menu['categories'] as List?)?.cast<Json>() ?? const [];
                final allItems = (menu['items'] as List?)?.cast<Json>() ?? const [];

                // Filter items
                final filtered = allItems.where((it) {
                  if (_selectedCategory != null && it['category_id'] != _selectedCategory) {
                    return false;
                  }
                  if (_searchQuery.isNotEmpty) {
                    final name = '${it['name']}'.toLowerCase();
                    final code = '${it['code'] ?? ''}'.toLowerCase();
                    if (!name.contains(_searchQuery) && !code.contains(_searchQuery)) {
                      return false;
                    }
                  }
                  return true;
                }).toList();

                return Column(
                  children: [
                    // Category Chips Bar
                    SizedBox(
                      height: 48,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: HPSpace.lg),
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: HPSpace.sm),
                            child: ChoiceChip(
                              label: const Text('All Items'),
                              selected: _selectedCategory == null,
                              onSelected: (_) => setState(() => _selectedCategory = null),
                            ),
                          ),
                          for (final cat in categories)
                            Padding(
                              padding: const EdgeInsets.only(right: HPSpace.sm),
                              child: ChoiceChip(
                                label: Text('${cat['name']}'),
                                selected: _selectedCategory == cat['id'],
                                onSelected: (_) => setState(() => _selectedCategory = cat['id'] as String),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: HPSpace.sm),

                    // Items List
                    Expanded(
                      child: filtered.isEmpty
                          ? const EmptyState(
                              icon: Icons.restaurant_menu_rounded,
                              title: 'No matching dishes',
                              message: 'Try selecting another category or clearing your search.',
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(HPSpace.lg),
                              itemCount: filtered.length,
                              itemBuilder: (context, idx) {
                                final it = filtered[idx];
                                final isAvail = it['available'] == 1 || it['available'] == true;
                                final isVeg = it['is_veg'] == 1 || it['is_veg'] == true;
                                final id = it['id'] as String;
                                final name = '${it['name']}';
                                final busy = _toggling.contains(id);

                                return Card(
                                  margin: const EdgeInsets.only(bottom: HPSpace.sm),
                                  child: Padding(
                                    padding: const EdgeInsets.all(HPSpace.md),
                                    child: Row(
                                      children: [
                                        // Veg / Non-veg dot
                                        Container(
                                          width: 18,
                                          height: 18,
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: isVeg ? Colors.green.shade700 : Colors.red.shade800,
                                              width: 2,
                                            ),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          alignment: Alignment.center,
                                          child: Container(
                                            width: 8,
                                            height: 8,
                                            decoration: BoxDecoration(
                                              color: isVeg ? Colors.green.shade700 : Colors.red.shade800,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: HPSpace.md),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(name, style: HPType.label(p.text)),
                                              Row(
                                                children: [
                                                  Text(
                                                    rupees(it['price_paise'] as int? ?? 0),
                                                    style: HPType.body(p.accentInk).copyWith(fontWeight: FontWeight.w600),
                                                  ),
                                                  if (it['code'] != null && '${it['code']}'.isNotEmpty) ...[
                                                    const SizedBox(width: HPSpace.sm),
                                                    Text('· ${it['code']}', style: HPType.body(p.muted).copyWith(fontSize: 12)),
                                                  ],
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        // 86 Toggle button
                                        if (busy)
                                          const SizedBox(
                                            width: 32,
                                            height: 32,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          )
                                        else
                                          FilledButton.tonal(
                                            key: Key('toggle-avail-$id'),
                                            style: FilledButton.styleFrom(
                                              backgroundColor: isAvail
                                                  ? Colors.green.withValues(alpha: .15)
                                                  : Colors.red.withValues(alpha: .15),
                                              foregroundColor: isAvail ? Colors.green.shade800 : Colors.red.shade800,
                                            ),
                                            onPressed: () => _toggleAvailability(id, name),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  isAvail ? Icons.check_circle_rounded : Icons.block_rounded,
                                                  size: 16,
                                                ),
                                                const SizedBox(width: HPSpace.xs),
                                                Text(isAvail ? 'In Stock' : '86 / Out'),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 3. STAFF & TEAM SCREEN
// ============================================================================

class StaffManagementScreen extends ConsumerWidget {
  const StaffManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(hubApiProvider);
    if (api == null) return const Scaffold(body: LoadingState());
    final p = context.hp;

    return Scaffold(
      body: Column(
        children: [
          const PosTopBar(
            title: 'Staff & Team',
            subtitle: 'Roles and terminal PIN status',
          ),
          Expanded(
            child: FutureBuilder<List<Json>>(
              future: api.staff(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return ErrorState(message: errText(snapshot.error!));
                }
                if (!snapshot.hasData) return const LoadingState(label: 'Loading staff…');

                final staff = snapshot.data!;
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: ListView(
                      padding: const EdgeInsets.all(HPSpace.lg),
                      children: [
                        for (final u in staff)
                          Card(
                            margin: const EdgeInsets.only(bottom: HPSpace.sm),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: roleColor(context, (u['roles'] as List?)?.firstOrNull?.toString())
                                    .withValues(alpha: .22),
                                child: Text(
                                  '${u['name']}'.characters.first.toUpperCase(),
                                  style: HPType.label(p.text),
                                ),
                              ),
                              title: Text('${u['name']}'.split(' (').first, style: HPType.label(p.text)),
                              subtitle: Text(
                                roleLabel(u['roles'] as List? ?? const []),
                                style: HPType.body(p.muted),
                              ),
                              trailing: u['hasPin'] == true
                                  ? StatusChip(label: 'PIN active', tone: HPTone.success, icon: Icons.lock_outline_rounded)
                                  : StatusChip(label: 'No PIN set', tone: HPTone.danger, icon: Icons.lock_open_rounded),
                            ),
                          ),
                        const SizedBox(height: HPSpace.lg),

                        // Roles & Permissions matrix summary
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(HPSpace.lg),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.shield_outlined, color: p.accentInk),
                                    const SizedBox(width: HPSpace.sm),
                                    Text('Roles & Responsibilities', style: HPType.titleCard(p.text)),
                                  ],
                                ),
                                const SizedBox(height: HPSpace.sm),
                                Text(
                                  '• Owner: Full authority over menu, bills, reversals, staff, discounts, and reports.\n'
                                  '• Cashier: Taking orders, generating bills, and processing payments.\n'
                                  '• Waiter: Creating orders, sending kitchen tickets (KOT), and table transfers.\n'
                                  '• Chef: Kitchen Display System (KDS), ticket status updates, and recipe viewing.\n'
                                  '• IT Admin: Hub pairing, printer setup, device health, and network config.\n'
                                  '• Auditor: Read-only access to bills, audit records, and sales reports.',
                                  style: HPType.body(p.muted).copyWith(height: 1.5),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 4. FLOORS & TABLES OVERVIEW SCREEN
// ============================================================================

class FloorsOverviewScreen extends ConsumerWidget {
  const FloorsOverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(hubApiProvider);
    if (api == null) return const Scaffold(body: LoadingState());
    final p = context.hp;

    return Scaffold(
      body: Column(
        children: [
          const PosTopBar(
            title: 'Floors & Capacity',
            subtitle: 'Floor plans, table counts and occupancy',
          ),
          Expanded(
            child: FutureBuilder<Json>(
              future: api.state(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return ErrorState(message: errText(snapshot.error!));
                }
                if (!snapshot.hasData) return const LoadingState(label: 'Loading floor data…');

                final state = snapshot.data!;
                final floors = (state['floors'] as List?)?.cast<Json>() ?? const [];
                final tables = (state['tables'] as List?)?.cast<Json>() ?? const [];

                // Metrics
                final totalTables = tables.length;
                final occupiedTables = tables.where((t) => t['status'] == 'occupied' || t['status'] == 'bill_printed').length;
                final freeTables = tables.where((t) => t['status'] == 'free').length;
                final reservedTables = tables.where((t) => t['status'] == 'reserved').length;
                final totalSeats = tables.fold<int>(0, (acc, t) => acc + ((t['seats'] as int?) ?? 0));

                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: ListView(
                      padding: const EdgeInsets.all(HPSpace.lg),
                      children: [
                        // KPI row
                        Wrap(
                          spacing: HPSpace.md,
                          runSpacing: HPSpace.md,
                          children: [
                            SizedBox(
                              width: 160,
                              child: KpiCard(
                                label: 'Total Tables',
                                value: '$totalTables',
                                caption: '$totalSeats total seats',
                                icon: Icons.table_restaurant_rounded,
                              ),
                            ),
                            SizedBox(
                              width: 160,
                              child: KpiCard(
                                label: 'Occupied',
                                value: '$occupiedTables',
                                caption: totalTables > 0 ? '${((occupiedTables / totalTables) * 100).toInt()}% occupancy' : '0%',
                                icon: Icons.people_alt_outlined,
                                tone: occupiedTables > 0 ? HPTone.saffron : HPTone.neutral,
                              ),
                            ),
                            SizedBox(
                              width: 160,
                              child: KpiCard(
                                label: 'Free',
                                value: '$freeTables',
                                caption: 'Ready for guests',
                                icon: Icons.check_circle_outline_rounded,
                                tone: HPTone.success,
                              ),
                            ),
                            SizedBox(
                              width: 160,
                              child: KpiCard(
                                label: 'Reserved',
                                value: '$reservedTables',
                                caption: 'Booked tables',
                                icon: Icons.bookmark_border_rounded,
                                tone: HPTone.pending,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: HPSpace.lg),

                        // Floors breakdown
                        for (final fl in floors) ...[
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(HPSpace.lg),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text('${fl['name']}', style: HPType.titleCard(p.text)),
                                      StatusChip(
                                        label: '${tables.where((t) => t['floor_id'] == fl['id']).length} tables',
                                        tone: HPTone.neutral,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: HPSpace.md),
                                  Wrap(
                                    spacing: HPSpace.sm,
                                    runSpacing: HPSpace.sm,
                                    children: [
                                      for (final t in tables.where((t) => t['floor_id'] == fl['id']))
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: HPSpace.md, vertical: HPSpace.sm),
                                          decoration: BoxDecoration(
                                            color: p.raised,
                                            borderRadius: BorderRadius.circular(10),
                                            border: Border.all(
                                              color: t['status'] == 'occupied'
                                                  ? HPColors.saffron
                                                  : (t['status'] == 'bill_printed' ? HPColors.cardamom : p.line),
                                            ),
                                          ),
                                          child: Column(
                                            children: [
                                              Text('Table ${t['name']}', style: HPType.label(p.text)),
                                              Text(
                                                '${t['seats']} seats · ${t['status']}',
                                                style: HPType.body(p.muted).copyWith(fontSize: 11),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: HPSpace.md),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 5. RESTAURANT PROFILE & LICENSE SCREEN
// ============================================================================

class RestaurantProfileScreen extends ConsumerWidget {
  const RestaurantProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(hubApiProvider);
    if (api == null) return const Scaffold(body: LoadingState());
    final p = context.hp;
    final setup = ref.watch(setupProvider).valueOrNull;

    return Scaffold(
      body: Column(
        children: [
          const PosTopBar(
            title: 'Restaurant & License',
            subtitle: 'Profile, subscription tier and sync details',
          ),
          Expanded(
            child: FutureBuilder<Json>(
              future: api.branch(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return ErrorState(message: errText(snapshot.error!));
                }
                if (!snapshot.hasData) return const LoadingState(label: 'Loading profile…');

                final data = snapshot.data!;
                final tenant = (data['tenant'] as Map?)?.cast<String, dynamic>() ?? const {};
                final branch = (data['branch'] as Map?)?.cast<String, dynamic>() ?? const {};

                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: const EdgeInsets.all(HPSpace.lg),
                      children: [
                        // Restaurant info
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(HPSpace.lg),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: HPColors.saffron.withValues(alpha: .18),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Icon(Icons.storefront_rounded, color: p.accentInk),
                                    ),
                                    const SizedBox(width: HPSpace.md),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text('${tenant['name'] ?? 'Restaurant'}', style: HPType.titleCard(p.text)),
                                          Text('Branch: ${branch['name'] ?? branch['code'] ?? 'Main'}', style: HPType.body(p.muted)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: HPSpace.lg),
                                Divider(color: p.line),
                                const SizedBox(height: HPSpace.sm),
                                _infoRow(p, 'Restaurant Code', '${tenant['code'] ?? 'R000000'}'),
                                _infoRow(p, 'Branch Code', '${branch['code'] ?? 'BR01'}'),
                                if (tenant['gstin'] != null && '${tenant['gstin']}'.isNotEmpty)
                                  _infoRow(p, 'GSTIN', '${tenant['gstin']}'),
                                if (tenant['address'] != null && '${tenant['address']}'.isNotEmpty)
                                  _infoRow(p, 'Address', '${tenant['address']}'),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: HPSpace.lg),

                        // Subscription & License Plan
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(HPSpace.lg),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.workspace_premium_rounded, color: p.accentInk),
                                    const SizedBox(width: HPSpace.sm),
                                    Text('Subscription Plan', style: HPType.titleCard(p.text)),
                                    const Spacer(),
                                    StatusChip(label: 'Active · Premium', tone: HPTone.success),
                                  ],
                                ),
                                const SizedBox(height: HPSpace.md),
                                Text(
                                  'Your subscription includes offline-first LAN hub, multi-terminal cashier sessions, '
                                  'Kitchen Display System (KDS), recipe inventory, and real-time business reports.',
                                  style: HPType.body(p.muted),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: HPSpace.lg),

                        // Cloud Sync Backend
                        FutureBuilder<Json>(
                          future: api.syncStatus(),
                          builder: (context, syncSnap) {
                            final syncData = syncSnap.data ?? const {};
                            final cloudUrl = setup?.hubConfig?.cloudUrl ?? const String.fromEnvironment('API_BASE_URL', defaultValue: 'https://rsaas-api.onrender.com/api/v1');
                            return Card(
                              child: Padding(
                                padding: const EdgeInsets.all(HPSpace.lg),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(Icons.cloud_done_rounded, color: p.accentInk),
                                        const SizedBox(width: HPSpace.sm),
                                        Text('Cloud Connection', style: HPType.titleCard(p.text)),
                                      ],
                                    ),
                                    const SizedBox(height: HPSpace.sm),
                                    _infoRow(p, 'Cloud Server', cloudUrl),
                                    if (syncData.isNotEmpty) ...[
                                      _infoRow(p, 'Events Synced', '${syncData['pushed'] ?? 0}'),
                                      _infoRow(p, 'Pending Sync', '${syncData['pending'] ?? 0}'),
                                      _infoRow(p, 'Failed', '${syncData['failed'] ?? 0}'),
                                      if (syncData['lastPullAt'] != null)
                                        _infoRow(p, 'Last Updated', clock12(syncData['lastPullAt'])),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(HPPalette p, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: HPType.body(p.muted)),
            Text(value, style: HPType.label(p.text)),
          ],
        ),
      );
}
