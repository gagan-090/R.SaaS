-- Staff web portal: custom roles, web access flag, PIN invite/reset tokens. Additive only.
ALTER TYPE "RestaurantRole" ADD VALUE IF NOT EXISTS 'custom';

CREATE TABLE "custom_roles" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "description" TEXT,
    "permissions" TEXT[],
    "deleted" BOOLEAN NOT NULL DEFAULT false,
    "seq" BIGINT NOT NULL DEFAULT 0,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,
    CONSTRAINT "custom_roles_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "custom_roles_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "restaurant_tenants"("id") ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE UNIQUE INDEX "custom_roles_tenant_id_name_key" ON "custom_roles"("tenant_id", "name");

ALTER TABLE "user_role_assignments" ADD COLUMN "custom_role_id" UUID;
ALTER TABLE "user_role_assignments" ADD CONSTRAINT "user_role_assignments_custom_role_id_fkey"
    FOREIGN KEY ("custom_role_id") REFERENCES "custom_roles"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE "users" ADD COLUMN "web_access" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "users" ADD COLUMN "pin_set_at" TIMESTAMPTZ(3);

CREATE TABLE "pin_tokens" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "token_hash" TEXT NOT NULL,
    "purpose" TEXT NOT NULL,
    "created_by" UUID,
    "expires_at" TIMESTAMPTZ(3) NOT NULL,
    "used_at" TIMESTAMPTZ(3),
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pin_tokens_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "pin_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE UNIQUE INDEX "pin_tokens_token_hash_key" ON "pin_tokens"("token_hash");
CREATE INDEX "pin_tokens_tenant_id_user_id_idx" ON "pin_tokens"("tenant_id", "user_id");

ALTER TABLE custom_roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON custom_roles USING (app_tenant_ok(tenant_id)) WITH CHECK (app_tenant_ok(tenant_id));
ALTER TABLE pin_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON pin_tokens USING (app_tenant_ok(tenant_id)) WITH CHECK (app_tenant_ok(tenant_id));
GRANT SELECT, INSERT, UPDATE, DELETE ON custom_roles, pin_tokens TO rsaas_app;
CREATE TRIGGER custom_roles_seq BEFORE INSERT OR UPDATE ON custom_roles FOR EACH ROW EXECUTE FUNCTION bump_config_seq();
