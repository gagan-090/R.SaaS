-- Restaurant codes (R000001…) come from a sequence so concurrent onboarding never collides.
CREATE SEQUENCE IF NOT EXISTS tenant_code_seq START 1;
SELECT setval('tenant_code_seq', COALESCE((SELECT MAX(substring(code FROM 2)::bigint) FROM restaurant_tenants WHERE code ~ '^R[0-9]+$'), 0) + 1, false);
GRANT USAGE, SELECT ON SEQUENCE tenant_code_seq TO rsaas_app;
