-- Super Admin platform: restaurant lifecycle (archived / deleted), plan tiers with monthly + yearly prices, the
-- billing cycle a customer bought, admin deletion, and records of cold-storage copies of logs. Additive.
-- Nothing here removes audit or ledger history: archives are verified copies; the append-only rules are unchanged.
-- AlterEnum
ALTER TYPE "AdminStatus" ADD VALUE 'deleted';

-- AlterEnum
-- This migration adds more than one value to an enum.
-- With PostgreSQL versions 11 and earlier, this is not possible
-- in a single migration. This can be worked around by creating
-- multiple migrations, each migration adding only one value to
-- the enum.


ALTER TYPE "TenantStatus" ADD VALUE 'archived';
ALTER TYPE "TenantStatus" ADD VALUE 'deleted';

-- AlterTable
ALTER TABLE "licenses" ADD COLUMN     "amount_paise" INTEGER NOT NULL DEFAULT 0,
ADD COLUMN     "billing_cycle" "BillingCycle" NOT NULL DEFAULT 'monthly';

-- AlterTable
ALTER TABLE "platform_admins" ADD COLUMN     "deleted_at" TIMESTAMPTZ(3);

-- AlterTable
ALTER TABLE "restaurant_tenants" ADD COLUMN     "status_changed_at" TIMESTAMPTZ(3);

-- AlterTable
ALTER TABLE "subscription_plans" ADD COLUMN     "tier" INTEGER NOT NULL DEFAULT 100,
ADD COLUMN     "yearly_price_paise" INTEGER NOT NULL DEFAULT 0;

-- CreateTable
CREATE TABLE "restaurant_archives" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "storage" TEXT NOT NULL,
    "storage_key" TEXT NOT NULL,
    "sha256" TEXT NOT NULL,
    "size_bytes" INTEGER NOT NULL,
    "counts" JSONB NOT NULL,
    "created_by" UUID NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "restored_at" TIMESTAMPTZ(3),
    "restored_by" UUID,

    CONSTRAINT "restaurant_archives_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "audit_archives" (
    "id" UUID NOT NULL,
    "before" TIMESTAMPTZ(3) NOT NULL,
    "storage" TEXT NOT NULL,
    "storage_key" TEXT NOT NULL,
    "sha256" TEXT NOT NULL,
    "size_bytes" INTEGER NOT NULL,
    "count" INTEGER NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "audit_archives_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "restaurant_archives_tenant_id_idx" ON "restaurant_archives"("tenant_id");


ALTER TABLE "restaurant_registrations" ADD COLUMN "billing_cycle" "BillingCycle" NOT NULL DEFAULT 'monthly';

-- ---- backfills
UPDATE "restaurant_tenants" SET "status_changed_at" = "updated_at" WHERE "status_changed_at" IS NULL;
UPDATE "subscription_plans" SET "tier" = CASE "code" WHEN 'standard' THEN 1 WHEN 'professional' THEN 2 WHEN 'premium' THEN 3 ELSE 100 END;
UPDATE "subscription_plans" SET "yearly_price_paise" = "price_paise" * 12 WHERE "yearly_price_paise" = 0;
UPDATE "licenses" l SET "billing_cycle" = p."billing_cycle",
  "amount_paise" = CASE WHEN p."billing_cycle" = 'yearly' THEN p."yearly_price_paise" ELSE p."price_paise" END
  FROM "subscription_plans" p WHERE p."id" = l."plan_id";

-- ---- tenancy for the new tables
ALTER TABLE restaurant_archives ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON restaurant_archives USING (app_tenant_ok(tenant_id)) WITH CHECK (app_tenant_ok(tenant_id));
GRANT SELECT, INSERT, UPDATE ON restaurant_archives TO rsaas_app;
ALTER TABLE audit_archives ENABLE ROW LEVEL SECURITY;
CREATE POLICY platform_only ON audit_archives USING (coalesce(current_setting('app.platform', true), '') = 'on') WITH CHECK (coalesce(current_setting('app.platform', true), '') = 'on');
GRANT SELECT, INSERT ON audit_archives TO rsaas_app;
