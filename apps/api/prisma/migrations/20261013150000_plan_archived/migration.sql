-- Plans are never deleted (licenses reference them); archived plans are hidden from sale but keep working for existing licenses.
ALTER TABLE "subscription_plans" ADD COLUMN "archived" BOOLEAN NOT NULL DEFAULT false;
