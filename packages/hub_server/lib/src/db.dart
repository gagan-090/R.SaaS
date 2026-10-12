import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// SQLite schema of the branch hub. The hub is the single writer for live operations; every write and its
/// outbox event commit in one transaction. Money columns are integer paise.
const _schemaV1 = <String>[
  'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  // ---- config pulled from the cloud (read-only on the hub)
  '''CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL, pin_hash TEXT,
       roles_json TEXT NOT NULL DEFAULT '[]')''',
  'CREATE TABLE floors (id TEXT PRIMARY KEY, name TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)',
  '''CREATE TABLE tables (id TEXT PRIMARY KEY, floor_id TEXT NOT NULL, name TEXT NOT NULL, seats INTEGER NOT NULL,
       layout_x INTEGER NOT NULL DEFAULT 0, layout_y INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)''',
  'CREATE TABLE tax_rules (id TEXT PRIMARY KEY, name TEXT NOT NULL, rate_bp INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)',
  '''CREATE TABLE items (id TEXT PRIMARY KEY, category_id TEXT NOT NULL, name TEXT NOT NULL, price_paise INTEGER NOT NULL,
       tax_rule_id TEXT NOT NULL, available INTEGER NOT NULL DEFAULT 1, is_veg INTEGER NOT NULL DEFAULT 1,
       plate_colors TEXT, deleted INTEGER NOT NULL DEFAULT 0)''',
  // ---- devices & sessions
  '''CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
       paired_at TEXT NOT NULL, revoked_at TEXT)''',
  'CREATE TABLE pairing_codes (code_hash TEXT PRIMARY KEY, expires_at TEXT NOT NULL, used_at TEXT, failed_attempts INTEGER NOT NULL DEFAULT 0)',
  '''CREATE TABLE sessions (token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, device_id TEXT NOT NULL,
       created_at TEXT NOT NULL, expires_at TEXT NOT NULL)''',
  // ---- live operations (hub is writer)
  '''CREATE TABLE orders (id TEXT PRIMARY KEY, type TEXT NOT NULL CHECK (type IN ('dine_in','takeaway')), table_id TEXT,
       waiter_id TEXT, status TEXT NOT NULL CHECK (status IN ('open','billed','paid','cancelled')), opened_by TEXT NOT NULL,
       opened_at TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1, updated_at TEXT NOT NULL)''',
  // A table holds at most one live order — enforced by the database, so a transfer or open can never double-book.
  "CREATE UNIQUE INDEX one_live_order_per_table ON orders(table_id) WHERE table_id IS NOT NULL AND status IN ('open','billed')",
  '''CREATE TABLE order_lines (id TEXT PRIMARY KEY, order_id TEXT NOT NULL REFERENCES orders(id), menu_item_id TEXT NOT NULL,
       name_snapshot TEXT NOT NULL, price_snapshot_paise INTEGER NOT NULL, tax_rate_snapshot_bp INTEGER NOT NULL,
       qty INTEGER NOT NULL CHECK (qty > 0), notes TEXT, status TEXT NOT NULL CHECK (status IN ('pending','sent','reversed')),
       sent_at TEXT, reversed_at TEXT, reversed_by TEXT, reversal_reason TEXT, reversal_approved_by TEXT, created_at TEXT NOT NULL)''',
  'CREATE INDEX order_lines_order ON order_lines(order_id)',
  '''CREATE TABLE order_status_history (id TEXT PRIMARY KEY, order_id TEXT NOT NULL, from_status TEXT, to_status TEXT NOT NULL,
       actor TEXT NOT NULL, at TEXT NOT NULL)''',
  '''CREATE TABLE table_transfers (id TEXT PRIMARY KEY, order_id TEXT NOT NULL, from_table_id TEXT NOT NULL, to_table_id TEXT NOT NULL,
       actor TEXT NOT NULL, at TEXT NOT NULL)''',
  '''CREATE TABLE kitchen_tickets (id TEXT PRIMARY KEY, order_id TEXT NOT NULL, kot_no INTEGER NOT NULL, line_ids_json TEXT NOT NULL,
       status TEXT NOT NULL DEFAULT 'new', created_at TEXT NOT NULL, accepted_at TEXT, preparing_at TEXT, ready_at TEXT, served_at TEXT)''',
  '''CREATE TABLE bills (id TEXT PRIMARY KEY, order_id TEXT NOT NULL UNIQUE, invoice_no TEXT NOT NULL UNIQUE,
       subtotal_paise INTEGER NOT NULL, discount_paise INTEGER NOT NULL, cgst_paise INTEGER NOT NULL, sgst_paise INTEGER NOT NULL,
       tip_paise INTEGER NOT NULL, round_off_paise INTEGER NOT NULL, total_paise INTEGER NOT NULL,
       discount_json TEXT, discount_reason TEXT, status TEXT NOT NULL CHECK (status IN ('open','paid')),
       created_at TEXT NOT NULL, closed_at TEXT)''',
  // Paid bills are immutable (corrections are bill_adjustments).
  '''CREATE TRIGGER bills_paid_immutable BEFORE UPDATE ON bills WHEN OLD.status = 'paid'
       BEGIN SELECT RAISE(ABORT, 'bill is paid and cannot be modified'); END''',
  '''CREATE TABLE bill_adjustments (id TEXT PRIMARY KEY, bill_id TEXT NOT NULL REFERENCES bills(id), type TEXT NOT NULL,
       amount_paise INTEGER NOT NULL, reason TEXT NOT NULL, approved_by TEXT, actor TEXT NOT NULL, at TEXT NOT NULL)''',
  '''CREATE TABLE payments (id TEXT PRIMARY KEY, bill_id TEXT NOT NULL REFERENCES bills(id), mode TEXT NOT NULL,
       amount_paise INTEGER NOT NULL, tendered_paise INTEGER, change_paise INTEGER NOT NULL DEFAULT 0, reference TEXT,
       idempotency_key TEXT NOT NULL UNIQUE, response_json TEXT NOT NULL, actor TEXT NOT NULL, at TEXT NOT NULL)''',
  '''CREATE TABLE tip_allocations (id TEXT PRIMARY KEY, bill_id TEXT NOT NULL UNIQUE REFERENCES bills(id), waiter_id TEXT NOT NULL,
       amount_paise INTEGER NOT NULL, actor TEXT NOT NULL, at TEXT NOT NULL)''',
  '''CREATE TABLE invoice_counters (branch_code TEXT NOT NULL, fy TEXT NOT NULL, last_number INTEGER NOT NULL,
       PRIMARY KEY (branch_code, fy))''',
  '''CREATE TABLE audit_events (id TEXT PRIMARY KEY, actor TEXT, action TEXT NOT NULL, object_type TEXT, object_id TEXT,
       before_json TEXT, after_json TEXT, reason TEXT, device_id TEXT, at TEXT NOT NULL)''',
  '''CREATE TRIGGER audit_append_only_u BEFORE UPDATE ON audit_events BEGIN SELECT RAISE(ABORT, 'audit_events is append-only'); END''',
  '''CREATE TRIGGER audit_append_only_d BEFORE DELETE ON audit_events BEGIN SELECT RAISE(ABORT, 'audit_events is append-only'); END''',
  // ---- sync outbox (hub → cloud)
  '''CREATE TABLE sync_outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE, entity TEXT NOT NULL,
       entity_id TEXT NOT NULL, op TEXT NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL,
       status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','pushed','failed')),
       pushed_at TEXT, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT)''',
  'CREATE INDEX sync_outbox_pending ON sync_outbox(status, seq)',
];

/// drift database without code generation: the schema is plain SQL above and queries go through
/// [query]/[execute]. drift provides the executor, transactions (nested = savepoints) and migrations.
class HubDatabase extends GeneratedDatabase {
  HubDatabase(super.executor);

  factory HubDatabase.memory() => HubDatabase(NativeDatabase.memory());
  factory HubDatabase.file(File file) => HubDatabase(NativeDatabase.createInBackground(file));

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  Iterable<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          for (final s in _schemaV1) {
            await customStatement(s);
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  static Variable<Object> _v(Object? x) => switch (x) {
        null => const Variable<String>(null),
        final bool b => Variable<bool>(b),
        final int i => Variable<int>(i),
        final String s => Variable<String>(s),
        _ => throw ArgumentError('unsupported SQL argument type ${x.runtimeType}'),
      };

  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> args = const []]) async {
    final rows = await customSelect(sql, variables: args.map(_v).toList()).get();
    return rows.map((r) => r.data).toList();
  }

  Future<Map<String, Object?>?> selectOne(String sql, [List<Object?> args = const []]) async {
    final rows = await query(sql, args);
    return rows.isEmpty ? null : rows.first;
  }

  /// Runs an INSERT/UPDATE/DELETE and returns the number of affected rows.
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      customUpdate(sql, variables: args.map(_v).toList(), updateKind: UpdateKind.update);

  Future<String?> getMeta(String key) async => (await selectOne('SELECT value FROM meta WHERE key = ?', [key]))?['value'] as String?;

  Future<void> setMeta(String key, String value) =>
      execute('INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', [key, value]);
}
