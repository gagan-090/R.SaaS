-- Inventory (plan feature "inventory"): products, suppliers, locations, the append-only stock ledger, recipes,
-- replenishment requests and expenses. Additive only.
-- CreateEnum
CREATE TYPE "StockMovementType" AS ENUM ('opening', 'purchase', 'sale', 'consumption', 'wastage', 'return_to_supplier', 'customer_return', 'count_adjustment', 'adjustment', 'transfer_out', 'transfer_in');

-- CreateTable
CREATE TABLE "inventory_locations" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "inventory_locations_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "suppliers" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "phone" TEXT,
    "email" TEXT,
    "gstin" TEXT,
    "active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "suppliers_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "inventory_products" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "sku" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "category" TEXT,
    "base_unit" TEXT NOT NULL,
    "purchase_unit" TEXT NOT NULL,
    "conversion_factor" DECIMAL(14,4) NOT NULL,
    "unit_cost_paise" INTEGER NOT NULL DEFAULT 0,
    "avg_cost_paise" DECIMAL(18,6) NOT NULL DEFAULT 0,
    "min_stock" DECIMAL(14,3) NOT NULL DEFAULT 0,
    "default_supplier_id" UUID,
    "default_location_id" UUID,
    "active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "inventory_products_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "stock_movements" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "product_id" UUID NOT NULL,
    "location_id" UUID,
    "type" "StockMovementType" NOT NULL,
    "quantity" DECIMAL(14,3) NOT NULL,
    "entered_qty" DECIMAL(14,3) NOT NULL,
    "entered_unit" TEXT NOT NULL,
    "value_paise" INTEGER NOT NULL,
    "unit_cost_paise" DECIMAL(18,6),
    "supplier_id" UUID,
    "reference" TEXT,
    "batch_number" TEXT,
    "expiry_date" DATE,
    "reason" TEXT,
    "source_type" TEXT,
    "source_id" TEXT,
    "idempotency_key" TEXT,
    "actor_id" UUID,
    "actor_role" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "stock_movements_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "recipe_lines" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "variant_id" UUID NOT NULL,
    "product_id" UUID NOT NULL,
    "quantity" DECIMAL(14,3) NOT NULL,
    "unit" TEXT NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "recipe_lines_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "replenishment_requests" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "product_id" UUID NOT NULL,
    "quantity" DECIMAL(14,3) NOT NULL,
    "unit" TEXT NOT NULL,
    "note" TEXT,
    "status" TEXT NOT NULL DEFAULT 'requested',
    "requested_by" UUID NOT NULL,
    "handled_by" UUID,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "replenishment_requests_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "expenses" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "category" TEXT NOT NULL,
    "description" TEXT NOT NULL,
    "amount_paise" INTEGER NOT NULL,
    "paid_on" DATE NOT NULL,
    "payment_mode" TEXT NOT NULL,
    "supplier_id" UUID,
    "reference" TEXT,
    "created_by" UUID NOT NULL,
    "voided_at" TIMESTAMPTZ(3),
    "voided_by" UUID,
    "void_reason" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "expenses_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "inventory_locations_tenant_id_name_key" ON "inventory_locations"("tenant_id", "name");

-- CreateIndex
CREATE UNIQUE INDEX "suppliers_tenant_id_name_key" ON "suppliers"("tenant_id", "name");

-- CreateIndex
CREATE UNIQUE INDEX "inventory_products_tenant_id_sku_key" ON "inventory_products"("tenant_id", "sku");

-- CreateIndex
CREATE INDEX "stock_movements_tenant_id_product_id_idx" ON "stock_movements"("tenant_id", "product_id");

-- CreateIndex
CREATE INDEX "stock_movements_tenant_id_created_at_idx" ON "stock_movements"("tenant_id", "created_at");

-- CreateIndex
CREATE UNIQUE INDEX "stock_movements_tenant_id_idempotency_key_key" ON "stock_movements"("tenant_id", "idempotency_key");

-- CreateIndex
CREATE UNIQUE INDEX "stock_movements_tenant_id_source_type_source_id_product_id_key" ON "stock_movements"("tenant_id", "source_type", "source_id", "product_id");

-- CreateIndex
CREATE INDEX "recipe_lines_tenant_id_idx" ON "recipe_lines"("tenant_id");

-- CreateIndex
CREATE UNIQUE INDEX "recipe_lines_variant_id_product_id_key" ON "recipe_lines"("variant_id", "product_id");

-- CreateIndex
CREATE INDEX "replenishment_requests_tenant_id_status_idx" ON "replenishment_requests"("tenant_id", "status");

-- CreateIndex
CREATE INDEX "expenses_tenant_id_paid_on_idx" ON "expenses"("tenant_id", "paid_on");

-- AddForeignKey
ALTER TABLE "stock_movements" ADD CONSTRAINT "stock_movements_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "inventory_products"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "recipe_lines" ADD CONSTRAINT "recipe_lines_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "menu_variants"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "recipe_lines" ADD CONSTRAINT "recipe_lines_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "inventory_products"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "replenishment_requests" ADD CONSTRAINT "replenishment_requests_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "inventory_products"("id") ON DELETE RESTRICT ON UPDATE CASCADE;


-- Tenant isolation for every new table.
DO $$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY['inventory_locations','suppliers','inventory_products','stock_movements','recipe_lines','replenishment_requests','expenses'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (app_tenant_ok(tenant_id)) WITH CHECK (app_tenant_ok(tenant_id))', tbl);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO rsaas_app', tbl);
  END LOOP;
END $$;

-- The stock ledger is append-only: corrections are new movements, never edits.
REVOKE UPDATE, DELETE, TRUNCATE ON stock_movements FROM rsaas_app;
CREATE OR REPLACE FUNCTION stock_movements_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'stock_movements is append-only; post a correcting movement';
END $$;
CREATE TRIGGER stock_movements_no_update BEFORE UPDATE OR DELETE ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION stock_movements_immutable();

-- Expenses are voided with a reason, never deleted.
REVOKE DELETE, TRUNCATE ON expenses FROM rsaas_app;

ALTER TABLE inventory_products ADD CONSTRAINT inventory_products_factor_positive CHECK (conversion_factor > 0);
ALTER TABLE inventory_products ADD CONSTRAINT inventory_products_min_nonnegative CHECK (min_stock >= 0);
ALTER TABLE recipe_lines ADD CONSTRAINT recipe_lines_qty_positive CHECK (quantity > 0);
ALTER TABLE expenses ADD CONSTRAINT expenses_amount_positive CHECK (amount_paise > 0);
