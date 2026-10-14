-- Audit context for the restaurant audit portal: actor role and name at the time, and a request id. Additive;
-- existing rows keep NULL (the portal falls back to the current name). The append-only trigger is unchanged.
ALTER TABLE "audit_events" ADD COLUMN "actor_role" TEXT;
ALTER TABLE "audit_events" ADD COLUMN "actor_name" TEXT;
ALTER TABLE "audit_events" ADD COLUMN "request_id" TEXT;
CREATE INDEX "audit_events_tenant_id_actor_id_idx" ON "audit_events"("tenant_id", "actor_id");
