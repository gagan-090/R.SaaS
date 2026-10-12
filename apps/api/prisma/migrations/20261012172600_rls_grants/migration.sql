-- Tenancy, least-privilege grants, append-only audit, config cursor, paid-bill immutability.
-- The API runs as rsaas_app (NOBYPASSRLS, not the table owner), so these policies apply to every query.
-- Context is set per transaction by the API:
--   set_config('app.tenant_id', '<uuid>', true)  → restaurant-scoped request
--   set_config('app.platform', 'on', true)       → platform admin / system request (cross-tenant)

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rsaas_app') THEN
    CREATE ROLE rsaas_app NOLOGIN NOSUPERUSER NOBYPASSRLS; -- password + LOGIN set by infra/db-init or CI
  END IF;
END $$;

CREATE OR REPLACE FUNCTION app_tenant_ok(t uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT coalesce(current_setting('app.platform', true), '') = 'on'
      OR (t IS NOT NULL AND t::text = coalesce(current_setting('app.tenant_id', true), ''))
$$;

-- Tenant-scoped tables: one policy for all commands.
DO $$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'franchises','branches','licenses','payment_records','users','user_role_assignments','devices',
    'floors','tables','tax_rules','menu_categories','menu_items',
    'orders','order_lines','order_status_history','table_transfers','bills','bill_adjustments',
    'payments','tip_allocations','sync_events','sync_conflicts'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (app_tenant_ok(tenant_id)) WITH CHECK (app_tenant_ok(tenant_id))', tbl);
  END LOOP;
END $$;

-- The tenant row itself is keyed by id.
ALTER TABLE restaurant_tenants ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON restaurant_tenants USING (app_tenant_ok(id)) WITH CHECK (app_tenant_ok(id));

-- Audit: readable within tenant (platform sees all incl. tenant_id NULL); insert only; never update/delete.
ALTER TABLE audit_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_select ON audit_events FOR SELECT USING (app_tenant_ok(tenant_id));
CREATE POLICY audit_insert ON audit_events FOR INSERT WITH CHECK (app_tenant_ok(tenant_id));

-- Grants for the runtime role.
GRANT USAGE ON SCHEMA public TO rsaas_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO rsaas_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO rsaas_app;
REVOKE UPDATE, DELETE, TRUNCATE ON audit_events FROM rsaas_app;
REVOKE UPDATE, DELETE, TRUNCATE ON sync_events FROM rsaas_app;
REVOKE ALL ON _prisma_migrations FROM rsaas_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO rsaas_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO rsaas_app;

-- Belt and braces: even a privileged role cannot rewrite audit history.
CREATE OR REPLACE FUNCTION audit_events_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_events is append-only';
END $$;
CREATE TRIGGER audit_events_no_update BEFORE UPDATE OR DELETE ON audit_events
  FOR EACH ROW EXECUTE FUNCTION audit_events_immutable();

-- Paid bills are never edited; corrections are bill_adjustments rows.
CREATE OR REPLACE FUNCTION bills_paid_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'paid' THEN
    RAISE EXCEPTION 'bill % is paid and cannot be modified; post a bill_adjustment', OLD.id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER bills_paid_no_update BEFORE UPDATE OR DELETE ON bills
  FOR EACH ROW EXECUTE FUNCTION bills_paid_immutable();

-- Config cursor for GET /sync/pull?since=<seq>: every insert/update of cloud-owned config gets a new seq.
CREATE SEQUENCE IF NOT EXISTS config_seq;
GRANT USAGE, SELECT ON SEQUENCE config_seq TO rsaas_app;
CREATE OR REPLACE FUNCTION bump_config_seq() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.seq := nextval('config_seq');
  RETURN NEW;
END $$;
DO $$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['branches','users','user_role_assignments','floors','tables','tax_rules','menu_categories','menu_items'] LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION bump_config_seq()', tbl || '_seq', tbl);
  END LOOP;
END $$;
