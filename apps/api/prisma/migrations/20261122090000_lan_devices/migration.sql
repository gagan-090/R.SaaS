-- What the branch's main device reports about the terminals signed in to it over Wi-Fi (name, platform, who is signed
-- in and their role), so the console can list every device. Written by POST /sync/devices with the hub's device token.
ALTER TABLE "devices" ADD COLUMN "lan_devices" JSONB;
ALTER TABLE "devices" ADD COLUMN "lan_reported_at" TIMESTAMPTZ(3);
