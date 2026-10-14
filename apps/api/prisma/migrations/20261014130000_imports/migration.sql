-- Excel import history (plan feature "import.excel"). Additive.
-- CreateTable
CREATE TABLE "import_jobs" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "kind" TEXT NOT NULL,
    "mode" TEXT NOT NULL,
    "file_name" TEXT NOT NULL,
    "file_size" INTEGER NOT NULL,
    "file_sha256" TEXT NOT NULL,
    "status" TEXT NOT NULL,
    "counts" JSONB NOT NULL,
    "errors" JSONB NOT NULL,
    "plan" JSONB NOT NULL,
    "result" JSONB,
    "actor_id" UUID NOT NULL,
    "actor_role" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "committed_at" TIMESTAMPTZ(3),

    CONSTRAINT "import_jobs_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "import_jobs_tenant_id_created_at_idx" ON "import_jobs"("tenant_id", "created_at");


ALTER TABLE import_jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON import_jobs USING (app_tenant_ok(tenant_id)) WITH CHECK (app_tenant_ok(tenant_id));
GRANT SELECT, INSERT, UPDATE ON import_jobs TO rsaas_app;
REVOKE DELETE, TRUNCATE ON import_jobs FROM rsaas_app;
