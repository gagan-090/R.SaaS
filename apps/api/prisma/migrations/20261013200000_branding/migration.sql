-- Restaurant branding (plan feature "branding"): colour, logo (media id) and text style, as one JSON object.
ALTER TABLE "restaurant_tenants" ADD COLUMN "branding" JSONB;
