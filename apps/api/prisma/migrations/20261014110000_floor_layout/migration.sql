-- Visual floor layout: table shape, position, size, rotation, chairs and manual status; floor canvas size and an
-- optimistic-lock version. Additive; existing tables get positions from their old grid coordinates.
ALTER TABLE "floors" ADD COLUMN "width" INTEGER NOT NULL DEFAULT 1200;
ALTER TABLE "floors" ADD COLUMN "height" INTEGER NOT NULL DEFAULT 800;
ALTER TABLE "floors" ADD COLUMN "layout_version" INTEGER NOT NULL DEFAULT 1;

ALTER TABLE "tables" ADD COLUMN "shape" TEXT NOT NULL DEFAULT 'square';
ALTER TABLE "tables" ADD COLUMN "pos_x" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "tables" ADD COLUMN "pos_y" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "tables" ADD COLUMN "width" INTEGER NOT NULL DEFAULT 80;
ALTER TABLE "tables" ADD COLUMN "height" INTEGER NOT NULL DEFAULT 80;
ALTER TABLE "tables" ADD COLUMN "rotation" INTEGER NOT NULL DEFAULT 0;
ALTER TABLE "tables" ADD COLUMN "chairs" JSONB;
ALTER TABLE "tables" ADD COLUMN "status" TEXT NOT NULL DEFAULT 'available';
ALTER TABLE "tables" ADD CONSTRAINT "tables_shape_check" CHECK ("shape" IN ('round','square','rect'));
ALTER TABLE "tables" ADD CONSTRAINT "tables_status_check" CHECK ("status" IN ('available','reserved','unavailable'));
ALTER TABLE "tables" ADD CONSTRAINT "tables_rotation_check" CHECK ("rotation" >= 0 AND "rotation" < 360);

-- old grid (0,2,4…) → canvas centres 150 units apart; 6+ seats become rectangles
UPDATE "tables" SET
  "pos_x" = 120 + "layout_x" * 75,
  "pos_y" = 120 + "layout_y" * 75,
  "shape" = CASE WHEN "seats" >= 6 THEN 'rect' WHEN "seats" <= 2 THEN 'round' ELSE 'square' END,
  "width" = CASE WHEN "seats" >= 6 THEN 140 ELSE 80 END,
  "height" = 80;
