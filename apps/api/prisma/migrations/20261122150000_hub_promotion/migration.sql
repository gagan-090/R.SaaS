-- The owner chose a Wi-Fi terminal as the new main device in the console: the current hub carries the request
-- ({ requestId, lanDeviceId, name, expiresAt, codeHash? }) until the terminal claims it with the one-time code the hub gave it.
ALTER TABLE "devices" ADD COLUMN "promotion" JSONB;
