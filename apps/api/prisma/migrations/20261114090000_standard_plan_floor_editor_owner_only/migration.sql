-- Standard plan: the visual floor editor (owners move tables on the floor) and owner only — one device, no employees.
-- Restaurants already on Standard get re-signed licenses when the API starts (LicenseService.resyncWithPlans).
UPDATE subscription_plans
SET feature_flags = CASE WHEN 'floor.editor' = ANY (feature_flags) THEN feature_flags ELSE array_append(feature_flags, 'floor.editor') END,
    limits = jsonb_set(limits::jsonb, '{staffPerBranch}', '0'::jsonb, true),
    updated_at = now()
WHERE code = 'standard';
