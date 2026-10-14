-- MFA remains enabled for every existing administrator until a Super Admin changes the policy.
ALTER TABLE "platform_admins" ADD COLUMN "mfa_enabled" BOOLEAN NOT NULL DEFAULT true;
