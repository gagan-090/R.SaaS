ALTER TABLE floors ADD COLUMN background_image TEXT;
CREATE TABLE table_reservations (
 id UUID PRIMARY KEY, tenant_id UUID NOT NULL REFERENCES restaurant_tenants(id),
 branch_id UUID NOT NULL REFERENCES branches(id), table_id UUID NOT NULL REFERENCES tables(id),
 guest_name TEXT NOT NULL, phone TEXT, guests INTEGER NOT NULL CHECK (guests > 0),
 starts_at TIMESTAMPTZ NOT NULL, ends_at TIMESTAMPTZ NOT NULL CHECK (ends_at > starts_at),
 status TEXT NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed','cancelled')),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX table_reservations_tenant_id_table_id_starts_at_idx ON table_reservations(tenant_id, table_id, starts_at);
ALTER TABLE table_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE table_reservations FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON table_reservations USING (app_tenant_ok(tenant_id)) WITH CHECK (app_tenant_ok(tenant_id));
GRANT SELECT, INSERT, UPDATE ON table_reservations TO rsaas_app;
