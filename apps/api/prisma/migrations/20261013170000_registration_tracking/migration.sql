-- Pending registrations are a Super Admin work queue: track sends and allow cancelling.
ALTER TABLE "restaurant_registrations" ADD COLUMN "cancelled_at" TIMESTAMPTZ(3);
ALTER TABLE "restaurant_registrations" ADD COLUMN "cancel_reason" TEXT;
ALTER TABLE "restaurant_registrations" ADD COLUMN "last_sent_at" TIMESTAMPTZ(3);
ALTER TABLE "restaurant_registrations" ADD COLUMN "send_count" INTEGER NOT NULL DEFAULT 1;
ALTER TABLE "restaurant_registrations" ADD COLUMN "last_email_error" TEXT;
UPDATE "restaurant_registrations" SET "last_sent_at" = "created_at";
