-- Menu variants (sizes / portions), stable item codes, active flags. Additive; existing items get one "Regular"
-- variant with their current price, so orders, reports and older hubs keep working.
ALTER TABLE "menu_categories" ADD COLUMN "active" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "menu_items" ADD COLUMN "active" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "menu_items" ADD COLUMN "code" TEXT;
UPDATE "menu_items" m SET "code" = 'ITEM-' || lpad(x.n::text, 4, '0')
  FROM (SELECT id, row_number() OVER (PARTITION BY tenant_id ORDER BY id) AS n FROM "menu_items") x WHERE x.id = m.id;
ALTER TABLE "menu_items" ALTER COLUMN "code" SET NOT NULL;
CREATE UNIQUE INDEX "menu_items_tenant_id_code_key" ON "menu_items"("tenant_id", "code");

CREATE TABLE "menu_variants" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "item_id" UUID NOT NULL,
    "code" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "portion_label" TEXT,
    "serving_quantity" DECIMAL(12,3),
    "serving_unit" TEXT,
    "portion_ratio" DECIMAL(6,3),
    "price_paise" INTEGER NOT NULL,
    "cost_price_paise" INTEGER,
    "tax_rule_id" UUID,
    "available" BOOLEAN NOT NULL DEFAULT true,
    "is_default" BOOLEAN NOT NULL DEFAULT false,
    "sort_order" INTEGER NOT NULL DEFAULT 0,
    "seq" BIGINT NOT NULL DEFAULT 0,
    "deleted" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,
    CONSTRAINT "menu_variants_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "menu_variants_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "menu_items"("id") ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT "menu_variants_price_nonnegative" CHECK ("price_paise" >= 0)
);
CREATE UNIQUE INDEX "menu_variants_tenant_id_code_key" ON "menu_variants"("tenant_id", "code");
CREATE INDEX "menu_variants_tenant_id_item_id_idx" ON "menu_variants"("tenant_id", "item_id");

ALTER TABLE menu_variants ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON menu_variants USING (app_tenant_ok(tenant_id)) WITH CHECK (app_tenant_ok(tenant_id));
GRANT SELECT, INSERT, UPDATE, DELETE ON menu_variants TO rsaas_app;
CREATE TRIGGER menu_variants_seq BEFORE INSERT OR UPDATE ON menu_variants FOR EACH ROW EXECUTE FUNCTION bump_config_seq();

INSERT INTO "menu_variants" ("id", "tenant_id", "item_id", "code", "name", "serving_quantity", "serving_unit", "portion_ratio",
                             "price_paise", "available", "is_default", "sort_order", "deleted", "updated_at")
SELECT gen_random_uuid(), tenant_id, id, code || '-STD', 'Regular', quantity, unit, 1, price_paise, available, true, 0, deleted, CURRENT_TIMESTAMP
FROM "menu_items";
