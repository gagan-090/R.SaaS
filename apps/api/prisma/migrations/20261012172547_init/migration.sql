-- CreateEnum
CREATE TYPE "AdminStatus" AS ENUM ('invited', 'active', 'disabled');

-- CreateEnum
CREATE TYPE "PermissionTier" AS ENUM ('platform', 'restaurant');

-- CreateEnum
CREATE TYPE "SubjectType" AS ENUM ('admin', 'user');

-- CreateEnum
CREATE TYPE "BillingCycle" AS ENUM ('monthly', 'yearly');

-- CreateEnum
CREATE TYPE "TenantStatus" AS ENUM ('pending', 'active', 'suspended', 'blocked');

-- CreateEnum
CREATE TYPE "LicenseStatus" AS ENUM ('active', 'revoked', 'superseded');

-- CreateEnum
CREATE TYPE "UserStatus" AS ENUM ('active', 'disabled');

-- CreateEnum
CREATE TYPE "RestaurantRole" AS ENUM ('owner', 'it_admin', 'cashier', 'waiter', 'chef', 'auditor');

-- CreateEnum
CREATE TYPE "DevicePlatform" AS ENUM ('windows', 'android', 'web');

-- CreateEnum
CREATE TYPE "OrderType" AS ENUM ('dine_in', 'takeaway');

-- CreateEnum
CREATE TYPE "OrderStatus" AS ENUM ('open', 'billed', 'paid', 'cancelled');

-- CreateEnum
CREATE TYPE "OrderLineStatus" AS ENUM ('pending', 'sent', 'reversed');

-- CreateEnum
CREATE TYPE "BillStatus" AS ENUM ('open', 'paid');

-- CreateEnum
CREATE TYPE "PaymentMode" AS ENUM ('cash', 'upi', 'card');

-- CreateTable
CREATE TABLE "platform_admins" (
    "id" UUID NOT NULL,
    "email" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "password_hash" TEXT,
    "status" "AdminStatus" NOT NULL DEFAULT 'invited',
    "failed_login_count" INTEGER NOT NULL DEFAULT 0,
    "locked_until" TIMESTAMPTZ(3),
    "last_login_at" TIMESTAMPTZ(3),
    "invite_token_hash" TEXT,
    "invite_expires_at" TIMESTAMPTZ(3),
    "invited_by_id" UUID,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "platform_admins_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "platform_roles" (
    "id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "description" TEXT,
    "permissions" TEXT[],
    "is_system" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "platform_roles_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "platform_admin_roles" (
    "admin_id" UUID NOT NULL,
    "role_id" UUID NOT NULL,
    "assigned_by" UUID,
    "assigned_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "platform_admin_roles_pkey" PRIMARY KEY ("admin_id","role_id")
);

-- CreateTable
CREATE TABLE "permissions" (
    "key" TEXT NOT NULL,
    "description" TEXT NOT NULL,
    "tier" "PermissionTier" NOT NULL,

    CONSTRAINT "permissions_pkey" PRIMARY KEY ("key")
);

-- CreateTable
CREATE TABLE "mfa_enrollments" (
    "id" UUID NOT NULL,
    "admin_id" UUID,
    "user_id" UUID,
    "totp_secret_encrypted" TEXT NOT NULL,
    "recovery_code_hashes" TEXT[],
    "enrolled_at" TIMESTAMPTZ(3),
    "last_used_step" INTEGER,
    "reset_by" UUID,
    "reset_at" TIMESTAMPTZ(3),
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "mfa_enrollments_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "refresh_tokens" (
    "id" UUID NOT NULL,
    "subject_type" "SubjectType" NOT NULL,
    "subject_id" UUID NOT NULL,
    "family_id" UUID NOT NULL,
    "token_hash" TEXT NOT NULL,
    "expires_at" TIMESTAMPTZ(3) NOT NULL,
    "revoked_at" TIMESTAMPTZ(3),
    "replaced_by" UUID,
    "user_agent" TEXT,
    "ip" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "refresh_tokens_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "notifications" (
    "id" UUID NOT NULL,
    "recipient" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "payload" JSONB NOT NULL,
    "sent_at" TIMESTAMPTZ(3),
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "notifications_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "subscription_plans" (
    "id" UUID NOT NULL,
    "code" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "feature_flags" TEXT[],
    "limits" JSONB NOT NULL,
    "price_paise" INTEGER NOT NULL,
    "billing_cycle" "BillingCycle" NOT NULL DEFAULT 'monthly',
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "subscription_plans_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "restaurant_registrations" (
    "id" UUID NOT NULL,
    "owner_email" TEXT NOT NULL,
    "owner_name" TEXT NOT NULL,
    "restaurant_name" TEXT NOT NULL,
    "gstin" TEXT,
    "address" TEXT,
    "plan_code" TEXT NOT NULL,
    "token_hash" TEXT NOT NULL,
    "expires_at" TIMESTAMPTZ(3) NOT NULL,
    "verified_at" TIMESTAMPTZ(3),
    "tenant_id" UUID,
    "created_by_id" UUID NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "restaurant_registrations_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "restaurant_tenants" (
    "id" UUID NOT NULL,
    "code" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "owner_email" TEXT NOT NULL,
    "gstin" TEXT,
    "address" TEXT,
    "status" "TenantStatus" NOT NULL DEFAULT 'pending',
    "status_reason" TEXT,
    "menu_version" INTEGER NOT NULL DEFAULT 0,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "restaurant_tenants_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "franchises" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "billing_contact" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "franchises_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "branches" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "franchise_id" UUID,
    "code" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "address" TEXT,
    "gstin" TEXT,
    "settings" JSONB NOT NULL DEFAULT '{}',
    "seq" BIGINT NOT NULL DEFAULT 0,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "branches_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "licenses" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "plan_id" UUID NOT NULL,
    "starts_at" TIMESTAMPTZ(3) NOT NULL,
    "ends_at" TIMESTAMPTZ(3) NOT NULL,
    "grace_days" INTEGER NOT NULL DEFAULT 7,
    "status" "LicenseStatus" NOT NULL DEFAULT 'active',
    "signed_token" TEXT NOT NULL,
    "issued_by" UUID NOT NULL,
    "reason" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "licenses_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "payment_records" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "license_id" UUID,
    "amount_paise" INTEGER NOT NULL,
    "method" TEXT NOT NULL,
    "reference" TEXT,
    "paid_at" TIMESTAMPTZ(3) NOT NULL,
    "recorded_by" UUID NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "payment_records_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "users" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "email" TEXT,
    "phone" TEXT,
    "password_hash" TEXT,
    "pin_hash" TEXT,
    "status" "UserStatus" NOT NULL DEFAULT 'active',
    "failed_login_count" INTEGER NOT NULL DEFAULT 0,
    "locked_until" TIMESTAMPTZ(3),
    "seq" BIGINT NOT NULL DEFAULT 0,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "users_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "user_role_assignments" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "role" "RestaurantRole" NOT NULL,
    "branch_ids" UUID[],
    "extra_permissions" TEXT[],
    "seq" BIGINT NOT NULL DEFAULT 0,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "user_role_assignments_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "devices" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "platform" "DevicePlatform" NOT NULL,
    "is_hub" BOOLEAN NOT NULL DEFAULT false,
    "device_token_hash" TEXT NOT NULL,
    "paired_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "last_seen_at" TIMESTAMPTZ(3),
    "revoked_at" TIMESTAMPTZ(3),

    CONSTRAINT "devices_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "floors" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "sort_order" INTEGER NOT NULL DEFAULT 0,
    "seq" BIGINT NOT NULL DEFAULT 0,
    "deleted" BOOLEAN NOT NULL DEFAULT false,

    CONSTRAINT "floors_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "tables" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "floor_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "seats" INTEGER NOT NULL DEFAULT 4,
    "layout_x" INTEGER NOT NULL DEFAULT 0,
    "layout_y" INTEGER NOT NULL DEFAULT 0,
    "seq" BIGINT NOT NULL DEFAULT 0,
    "deleted" BOOLEAN NOT NULL DEFAULT false,

    CONSTRAINT "tables_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "tax_rules" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "rate_bp" INTEGER NOT NULL,
    "seq" BIGINT NOT NULL DEFAULT 0,
    "deleted" BOOLEAN NOT NULL DEFAULT false,

    CONSTRAINT "tax_rules_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "menu_categories" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID,
    "name" TEXT NOT NULL,
    "sort_order" INTEGER NOT NULL DEFAULT 0,
    "seq" BIGINT NOT NULL DEFAULT 0,
    "deleted" BOOLEAN NOT NULL DEFAULT false,

    CONSTRAINT "menu_categories_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "menu_items" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "category_id" UUID NOT NULL,
    "name" TEXT NOT NULL,
    "description" TEXT,
    "unit" TEXT NOT NULL DEFAULT 'plate',
    "quantity" INTEGER NOT NULL DEFAULT 1,
    "price_paise" INTEGER NOT NULL,
    "tax_rule_id" UUID NOT NULL,
    "available" BOOLEAN NOT NULL DEFAULT true,
    "is_veg" BOOLEAN NOT NULL DEFAULT true,
    "image_id" UUID,
    "plate_colors" JSONB,
    "seq" BIGINT NOT NULL DEFAULT 0,
    "deleted" BOOLEAN NOT NULL DEFAULT false,

    CONSTRAINT "menu_items_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "orders" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "type" "OrderType" NOT NULL,
    "table_id" UUID,
    "waiter_id" UUID,
    "status" "OrderStatus" NOT NULL,
    "opened_by" UUID NOT NULL,
    "opened_at" TIMESTAMPTZ(3) NOT NULL,
    "version" INTEGER NOT NULL,

    CONSTRAINT "orders_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "order_lines" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "order_id" UUID NOT NULL,
    "menu_item_id" UUID NOT NULL,
    "name_snapshot" TEXT NOT NULL,
    "price_snapshot_paise" INTEGER NOT NULL,
    "tax_rate_snapshot_bp" INTEGER NOT NULL,
    "qty" INTEGER NOT NULL,
    "notes" TEXT,
    "status" "OrderLineStatus" NOT NULL,
    "sent_at" TIMESTAMPTZ(3),

    CONSTRAINT "order_lines_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "order_status_history" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "order_id" UUID NOT NULL,
    "from_status" TEXT,
    "to_status" TEXT NOT NULL,
    "actor" UUID NOT NULL,
    "at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "order_status_history_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "table_transfers" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "order_id" UUID NOT NULL,
    "from_table_id" UUID NOT NULL,
    "to_table_id" UUID NOT NULL,
    "actor" UUID NOT NULL,
    "at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "table_transfers_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "bills" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "order_id" UUID NOT NULL,
    "invoice_no" TEXT NOT NULL,
    "subtotal_paise" INTEGER NOT NULL,
    "discount_paise" INTEGER NOT NULL,
    "cgst_paise" INTEGER NOT NULL,
    "sgst_paise" INTEGER NOT NULL,
    "tip_paise" INTEGER NOT NULL,
    "round_off_paise" INTEGER NOT NULL,
    "total_paise" INTEGER NOT NULL,
    "status" "BillStatus" NOT NULL,
    "closed_at" TIMESTAMPTZ(3),
    "created_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "bills_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "bill_adjustments" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "bill_id" UUID NOT NULL,
    "type" TEXT NOT NULL,
    "amount_paise" INTEGER NOT NULL,
    "reason" TEXT NOT NULL,
    "approved_by" UUID,
    "actor" UUID NOT NULL,
    "at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "bill_adjustments_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "payments" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "bill_id" UUID NOT NULL,
    "mode" "PaymentMode" NOT NULL,
    "amount_paise" INTEGER NOT NULL,
    "tendered_paise" INTEGER,
    "reference" TEXT,
    "idempotency_key" TEXT NOT NULL,
    "at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "payments_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "tip_allocations" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "bill_id" UUID NOT NULL,
    "waiter_id" UUID NOT NULL,
    "amount_paise" INTEGER NOT NULL,

    CONSTRAINT "tip_allocations_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "audit_events" (
    "id" UUID NOT NULL,
    "tenant_id" UUID,
    "branch_id" UUID,
    "actor_id" UUID,
    "actor_type" TEXT,
    "action" TEXT NOT NULL,
    "object_type" TEXT,
    "object_id" TEXT,
    "before" JSONB,
    "after" JSONB,
    "reason" TEXT,
    "device_id" TEXT,
    "session_id" TEXT,
    "ip" TEXT,
    "at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "audit_events_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "sync_events" (
    "event_id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "entity" TEXT NOT NULL,
    "entity_id" TEXT NOT NULL,
    "op" TEXT NOT NULL,
    "payload" JSONB NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL,
    "received_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "sync_events_pkey" PRIMARY KEY ("event_id")
);

-- CreateTable
CREATE TABLE "sync_conflicts" (
    "id" UUID NOT NULL,
    "tenant_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "event_id" UUID NOT NULL,
    "reason" TEXT NOT NULL,
    "payload" JSONB NOT NULL,
    "detected_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "resolved_by" UUID,
    "resolution" TEXT,

    CONSTRAINT "sync_conflicts_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "platform_admins_email_key" ON "platform_admins"("email");

-- CreateIndex
CREATE UNIQUE INDEX "platform_admins_invite_token_hash_key" ON "platform_admins"("invite_token_hash");

-- CreateIndex
CREATE UNIQUE INDEX "platform_roles_name_key" ON "platform_roles"("name");

-- CreateIndex
CREATE UNIQUE INDEX "mfa_enrollments_admin_id_key" ON "mfa_enrollments"("admin_id");

-- CreateIndex
CREATE UNIQUE INDEX "mfa_enrollments_user_id_key" ON "mfa_enrollments"("user_id");

-- CreateIndex
CREATE UNIQUE INDEX "refresh_tokens_token_hash_key" ON "refresh_tokens"("token_hash");

-- CreateIndex
CREATE INDEX "refresh_tokens_subject_type_subject_id_idx" ON "refresh_tokens"("subject_type", "subject_id");

-- CreateIndex
CREATE INDEX "refresh_tokens_family_id_idx" ON "refresh_tokens"("family_id");

-- CreateIndex
CREATE UNIQUE INDEX "subscription_plans_code_key" ON "subscription_plans"("code");

-- CreateIndex
CREATE UNIQUE INDEX "restaurant_registrations_token_hash_key" ON "restaurant_registrations"("token_hash");

-- CreateIndex
CREATE INDEX "restaurant_registrations_owner_email_idx" ON "restaurant_registrations"("owner_email");

-- CreateIndex
CREATE UNIQUE INDEX "restaurant_tenants_code_key" ON "restaurant_tenants"("code");

-- CreateIndex
CREATE UNIQUE INDEX "restaurant_tenants_owner_email_key" ON "restaurant_tenants"("owner_email");

-- CreateIndex
CREATE INDEX "franchises_tenant_id_idx" ON "franchises"("tenant_id");

-- CreateIndex
CREATE UNIQUE INDEX "branches_tenant_id_code_key" ON "branches"("tenant_id", "code");

-- CreateIndex
CREATE INDEX "licenses_tenant_id_status_idx" ON "licenses"("tenant_id", "status");

-- CreateIndex
CREATE INDEX "payment_records_tenant_id_idx" ON "payment_records"("tenant_id");

-- CreateIndex
CREATE UNIQUE INDEX "users_email_key" ON "users"("email");

-- CreateIndex
CREATE INDEX "users_tenant_id_idx" ON "users"("tenant_id");

-- CreateIndex
CREATE INDEX "user_role_assignments_tenant_id_idx" ON "user_role_assignments"("tenant_id");

-- CreateIndex
CREATE UNIQUE INDEX "user_role_assignments_user_id_role_key" ON "user_role_assignments"("user_id", "role");

-- CreateIndex
CREATE UNIQUE INDEX "devices_device_token_hash_key" ON "devices"("device_token_hash");

-- CreateIndex
CREATE INDEX "devices_tenant_id_branch_id_idx" ON "devices"("tenant_id", "branch_id");

-- CreateIndex
CREATE INDEX "floors_tenant_id_branch_id_idx" ON "floors"("tenant_id", "branch_id");

-- CreateIndex
CREATE INDEX "tables_tenant_id_branch_id_idx" ON "tables"("tenant_id", "branch_id");

-- CreateIndex
CREATE UNIQUE INDEX "tables_branch_id_name_key" ON "tables"("branch_id", "name");

-- CreateIndex
CREATE INDEX "tax_rules_tenant_id_idx" ON "tax_rules"("tenant_id");

-- CreateIndex
CREATE INDEX "menu_categories_tenant_id_idx" ON "menu_categories"("tenant_id");

-- CreateIndex
CREATE INDEX "menu_items_tenant_id_idx" ON "menu_items"("tenant_id");

-- CreateIndex
CREATE INDEX "orders_tenant_id_branch_id_idx" ON "orders"("tenant_id", "branch_id");

-- CreateIndex
CREATE INDEX "order_lines_tenant_id_branch_id_idx" ON "order_lines"("tenant_id", "branch_id");

-- CreateIndex
CREATE INDEX "order_status_history_tenant_id_branch_id_idx" ON "order_status_history"("tenant_id", "branch_id");

-- CreateIndex
CREATE INDEX "table_transfers_tenant_id_branch_id_idx" ON "table_transfers"("tenant_id", "branch_id");

-- CreateIndex
CREATE INDEX "bills_tenant_id_branch_id_idx" ON "bills"("tenant_id", "branch_id");

-- CreateIndex
CREATE UNIQUE INDEX "bills_branch_id_invoice_no_key" ON "bills"("branch_id", "invoice_no");

-- CreateIndex
CREATE INDEX "bill_adjustments_tenant_id_branch_id_idx" ON "bill_adjustments"("tenant_id", "branch_id");

-- CreateIndex
CREATE INDEX "payments_tenant_id_branch_id_idx" ON "payments"("tenant_id", "branch_id");

-- CreateIndex
CREATE UNIQUE INDEX "payments_branch_id_idempotency_key_key" ON "payments"("branch_id", "idempotency_key");

-- CreateIndex
CREATE INDEX "tip_allocations_tenant_id_branch_id_idx" ON "tip_allocations"("tenant_id", "branch_id");

-- CreateIndex
CREATE INDEX "audit_events_tenant_id_at_idx" ON "audit_events"("tenant_id", "at");

-- CreateIndex
CREATE INDEX "audit_events_action_idx" ON "audit_events"("action");

-- CreateIndex
CREATE INDEX "sync_events_tenant_id_branch_id_idx" ON "sync_events"("tenant_id", "branch_id");

-- CreateIndex
CREATE UNIQUE INDEX "sync_conflicts_event_id_key" ON "sync_conflicts"("event_id");

-- CreateIndex
CREATE INDEX "sync_conflicts_tenant_id_branch_id_idx" ON "sync_conflicts"("tenant_id", "branch_id");

-- AddForeignKey
ALTER TABLE "platform_admin_roles" ADD CONSTRAINT "platform_admin_roles_admin_id_fkey" FOREIGN KEY ("admin_id") REFERENCES "platform_admins"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "platform_admin_roles" ADD CONSTRAINT "platform_admin_roles_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "platform_roles"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "mfa_enrollments" ADD CONSTRAINT "mfa_enrollments_admin_id_fkey" FOREIGN KEY ("admin_id") REFERENCES "platform_admins"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "mfa_enrollments" ADD CONSTRAINT "mfa_enrollments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "franchises" ADD CONSTRAINT "franchises_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "restaurant_tenants"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "branches" ADD CONSTRAINT "branches_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "restaurant_tenants"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "branches" ADD CONSTRAINT "branches_franchise_id_fkey" FOREIGN KEY ("franchise_id") REFERENCES "franchises"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "licenses" ADD CONSTRAINT "licenses_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "restaurant_tenants"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "licenses" ADD CONSTRAINT "licenses_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "subscription_plans"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "payment_records" ADD CONSTRAINT "payment_records_license_id_fkey" FOREIGN KEY ("license_id") REFERENCES "licenses"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "users" ADD CONSTRAINT "users_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "restaurant_tenants"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "user_role_assignments" ADD CONSTRAINT "user_role_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "tables" ADD CONSTRAINT "tables_floor_id_fkey" FOREIGN KEY ("floor_id") REFERENCES "floors"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "menu_items" ADD CONSTRAINT "menu_items_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "menu_categories"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "menu_items" ADD CONSTRAINT "menu_items_tax_rule_id_fkey" FOREIGN KEY ("tax_rule_id") REFERENCES "tax_rules"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "order_lines" ADD CONSTRAINT "order_lines_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "orders"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
