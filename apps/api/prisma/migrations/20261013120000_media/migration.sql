-- Menu photos uploaded from the restaurant console. Stored in Postgres (small, resized on the client) so a single
-- VPS needs no object store; S3 can replace the bytes column later without changing the API.
CREATE TABLE "media" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "content_type" TEXT NOT NULL,
    "bytes" BYTEA NOT NULL,
    "size_bytes" INTEGER NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "media_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "media_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "restaurant_tenants"("id") ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE INDEX "media_tenant_id_idx" ON "media"("tenant_id");

ALTER TABLE media ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON media USING (app_tenant_ok(tenant_id)) WITH CHECK (app_tenant_ok(tenant_id));
GRANT SELECT, INSERT, UPDATE, DELETE ON media TO rsaas_app;
