-- Custom branding (logo, colour, text style) is in every plan from Standard up. Restaurants already on these plans get
-- re-signed licenses when the API starts (LicenseService.resyncWithPlans).
UPDATE subscription_plans
SET feature_flags = array_append(feature_flags, 'branding'),
    updated_at = now()
WHERE code IN ('standard', 'professional') AND NOT ('branding' = ANY (feature_flags));
