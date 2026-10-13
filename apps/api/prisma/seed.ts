/* Seed: permissions, platform roles, 3 plans, the bootstrap Super Admin and one demo restaurant. Idempotent. */
import * as path from 'path';
import { randomBytes } from 'crypto';
import { config } from 'dotenv';
import { PrismaClient } from '@prisma/client';
import * as argon2 from 'argon2';
import { uuidv7 } from '../src/common/uuid';
import { PLAN_DEFAULTS, PLATFORM_PERMISSIONS, RESTAURANT_PERMISSIONS, ALL_PLATFORM_PERMISSIONS } from '../src/common/permissions';
import { signLicense } from '../src/licensing/license-token';

config({ path: path.resolve(__dirname, '../../../.env.local'), quiet: true });

const prisma = new PrismaClient();
const hash = (p: string) => argon2.hash(p, { type: argon2.argon2id, memoryCost: 19456, timeCost: 2, parallelism: 1 });
const need = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`${k} is required for seeding (see .env.example)`);
  return v;
};

const ROLES = [
  { name: 'Super Admin', description: 'All platform permissions', permissions: ALL_PLATFORM_PERMISSIONS, isSystem: true },
  {
    name: 'Onboarding Admin', description: 'Registers restaurants and manages licenses', isSystem: true,
    permissions: ['platform.restaurant.read', 'platform.restaurant.create', 'platform.restaurant.update', 'platform.restaurant.status', 'platform.license.manage', 'platform.payment.record'],
  },
  {
    name: 'Platform Auditor', description: 'Read-only access to restaurants, admins and the platform audit log', isSystem: true,
    permissions: ['platform.restaurant.read', 'platform.admin.read', 'platform.audit.read'],
  },
];

const DISHES = [
  { name: 'Butter Chicken', cat: 'Mains', price: 34000, tax: 500, veg: false, c: ['#D9622B', '#F2C27B', '#4F8A3B'] },
  { name: 'Paneer Tikka', cat: 'Starters', price: 26000, tax: 500, veg: true, c: ['#8A3B1F', '#F5E3C3', '#6FA14A'] },
  { name: 'Dal Makhani', cat: 'Mains', price: 22000, tax: 500, veg: true, c: ['#6B2E1E', '#E8D2A8', '#3F7D3A'] },
  { name: 'Garlic Naan', cat: 'Breads', price: 6000, tax: 500, veg: true, c: ['#E7C27D', '#B9823A', '#5E8F3E'] },
  { name: 'Biryani', cat: 'Mains', price: 32000, tax: 500, veg: false, c: ['#D99A2B', '#8B4A2B', '#F2E4C2'] },
  { name: 'Mango Lassi', cat: 'Drinks', price: 12000, tax: 1200, veg: true, c: ['#F2B33D', '#F7D27A', '#E07A2E'] },
  { name: 'Masala Chaas', cat: 'Drinks', price: 8000, tax: 1200, veg: true, c: ['#EFE8D6', '#CFE3C2', '#6E9B4E'] },
  { name: 'Gulab Jamun', cat: 'Desserts', price: 9000, tax: 1800, veg: true, c: ['#6E2A12', '#9C4520', '#E9C46A'] },
];

async function main() {
  // Permissions
  for (const [key, description] of Object.entries(PLATFORM_PERMISSIONS)) {
    await prisma.permission.upsert({ where: { key }, update: { description }, create: { key, description, tier: 'platform' } });
  }
  for (const [key, description] of Object.entries(RESTAURANT_PERMISSIONS)) {
    await prisma.permission.upsert({ where: { key }, update: { description }, create: { key, description, tier: 'restaurant' } });
  }
  // Platform roles
  for (const r of ROLES) {
    await prisma.platformRole.upsert({
      where: { name: r.name },
      update: { permissions: [...r.permissions], description: r.description },
      create: { ...r, permissions: [...r.permissions] },
    });
  }
  // Plans
  for (const p of PLAN_DEFAULTS) {
    await prisma.subscriptionPlan.upsert({
      where: { code: p.code },
      update: { name: p.name, featureFlags: [...p.featureFlags], limits: p.limits },
      create: { code: p.code, name: p.name, featureFlags: [...p.featureFlags], limits: p.limits, pricePaise: p.pricePaise },
    });
  }
  // Bootstrap Super Admin (MFA enrolment is forced at first login)
  const email = need('BOOTSTRAP_SUPERADMIN_EMAIL').toLowerCase();
  const superRole = await prisma.platformRole.findUniqueOrThrow({ where: { name: 'Super Admin' } });
  const existing = await prisma.platformAdmin.findUnique({ where: { email } });
  if (!existing) {
    await prisma.platformAdmin.create({
      data: {
        email, name: 'Super Admin', status: 'active', passwordHash: await hash(need('BOOTSTRAP_SUPERADMIN_PASSWORD')),
        roles: { create: { roleId: superRole.id } },
      },
    });
    console.log(`Created Super Admin ${email}`);
  }

  // Demo restaurant
  const demoEmail = 'owner@demo-dhaba.example';
  if (!(await prisma.restaurantTenant.findUnique({ where: { ownerEmail: demoEmail } }))) {
    const ownerPassword = process.env.DEMO_OWNER_PASSWORD || 'Demo-' + randomBytes(9).toString('base64url');
    const pin = '1234';
    const tenant = await prisma.restaurantTenant.create({
      data: { code: 'R000000', name: 'Demo Dhaba', ownerEmail: demoEmail, gstin: '27AAAPA1234A1Z5', address: 'MG Road, Pune', status: 'active' },
    });
    const branch = await prisma.branch.create({ data: { tenantId: tenant.id, code: 'BR01', name: 'Demo Dhaba — MG Road', gstin: tenant.gstin, address: tenant.address } });
    await prisma.user.create({
      data: {
        tenantId: tenant.id, name: 'Demo Owner', email: demoEmail, passwordHash: await hash(ownerPassword), pinHash: await hash(pin),
        roles: { create: { tenantId: tenant.id, role: 'owner', branchIds: [] } },
      },
    });
    const floor = await prisma.floor.create({ data: { tenantId: tenant.id, branchId: branch.id, name: 'Ground floor' } });
    for (let i = 1; i <= 8; i++) {
      await prisma.table.create({
        data: { tenantId: tenant.id, branchId: branch.id, floorId: floor.id, name: String(i), seats: i % 3 === 0 ? 6 : i % 2 ? 2 : 4, layoutX: ((i - 1) % 4) * 2, layoutY: Math.floor((i - 1) / 4) * 2 },
      });
    }
    const taxes: Record<number, string> = {};
    for (const bp of [0, 500, 1200, 1800]) {
      taxes[bp] = (await prisma.taxRule.create({ data: { tenantId: tenant.id, name: `GST ${bp / 100}%`, rateBp: bp } })).id;
    }
    const cats: Record<string, string> = {};
    let order = 0;
    for (const d of DISHES) {
      cats[d.cat] ??= (await prisma.menuCategory.create({ data: { tenantId: tenant.id, name: d.cat, sortOrder: order++ } })).id;
      await prisma.menuItem.create({
        data: {
          tenantId: tenant.id, categoryId: cats[d.cat], name: d.name, pricePaise: d.price, taxRuleId: taxes[d.tax], isVeg: d.veg,
          plateColors: { base: d.c[0], sauce: d.c[1], garnish: d.c[2] },
        },
      });
    }
    const plan = await prisma.subscriptionPlan.findUniqueOrThrow({ where: { code: DEMO_PLAN } });
    const id = uuidv7();
    const startsAt = new Date();
    const endsAt = new Date(Date.now() + 30 * 86400_000);
    const token = signLicense(
      {
        v: 1, lic: id, tid: tenant.id, plan: plan.code, features: plan.featureFlags, limits: plan.limits as Record<string, number | null>,
        nbf: Math.floor(startsAt.getTime() / 1000), exp: Math.floor(endsAt.getTime() / 1000), grace_days: 7, iat: Math.floor(Date.now() / 1000),
      },
      need('LICENSE_SIGNING_PRIVATE_KEY'),
    );
    const sa = await prisma.platformAdmin.findUniqueOrThrow({ where: { email } });
    await prisma.license.create({ data: { id, tenantId: tenant.id, planId: plan.id, startsAt, endsAt, signedToken: token, issuedBy: sa.id, reason: 'demo seed' } });
    console.log(`Created demo restaurant "Demo Dhaba" — owner ${demoEmail} / ${ownerPassword}; staff PIN ${pin}`);
  }
  await ensureDemoStaffAndPlan(demoEmail, email);
}

/** Demo plan: Premium by default so every role (incl. chef / IT admin / auditor and the KDS) can be tried. */
const DEMO_PLAN = (process.env.DEMO_PLAN || 'premium') as 'standard' | 'professional' | 'premium';

/** One PIN user per restaurant role (all PIN 1234) and a license on DEMO_PLAN. Idempotent, also for older seeds. */
async function ensureDemoStaffAndPlan(demoEmail: string, superAdminEmail: string) {
  const tenant = await prisma.restaurantTenant.findUniqueOrThrow({ where: { ownerEmail: demoEmail } });
  const staff: [string, 'cashier' | 'waiter' | 'chef' | 'it_admin' | 'auditor'][] = [
    ['Ravi (Cashier)', 'cashier'], ['Anita (Waiter)', 'waiter'], ['Sohan (Waiter)', 'waiter'],
    ['Kunal (Chef)', 'chef'], ['Imran (IT Admin)', 'it_admin'], ['Asha (Auditor)', 'auditor'],
  ];
  for (const [name, role] of staff) {
    if (await prisma.user.findFirst({ where: { tenantId: tenant.id, name } })) continue;
    await prisma.user.create({
      data: { tenantId: tenant.id, name, pinHash: await hash('1234'), roles: { create: { tenantId: tenant.id, role, branchIds: [] } } },
    });
    console.log(`Added demo ${role}: ${name} (PIN 1234)`);
  }
  const plan = await prisma.subscriptionPlan.findUniqueOrThrow({ where: { code: DEMO_PLAN } });
  const now = new Date();
  const current = await prisma.license.findFirst({ where: { tenantId: tenant.id, status: 'active' }, orderBy: { createdAt: 'desc' } });
  if (current && current.planId === plan.id && current.endsAt > now) return;
  await prisma.license.updateMany({ where: { tenantId: tenant.id, status: 'active' }, data: { status: 'superseded' } });
  const id = uuidv7();
  const endsAt = new Date(Date.now() + 30 * 86400_000);
  const token = signLicense(
    {
      v: 1, lic: id, tid: tenant.id, plan: plan.code, features: plan.featureFlags, limits: plan.limits as Record<string, number | null>,
      nbf: Math.floor(now.getTime() / 1000) - 60, exp: Math.floor(endsAt.getTime() / 1000), grace_days: 7, iat: Math.floor(Date.now() / 1000),
    },
    need('LICENSE_SIGNING_PRIVATE_KEY'),
  );
  const sa = await prisma.platformAdmin.findUniqueOrThrow({ where: { email: superAdminEmail } });
  await prisma.license.create({ data: { id, tenantId: tenant.id, planId: plan.id, startsAt: now, endsAt, signedToken: token, issuedBy: sa.id, reason: `demo seed: ${plan.code}`, status: 'active' } });
  console.log(`Demo restaurant licensed on ${plan.code}`);
}

main()
  .then(() => prisma.$disconnect())
  .catch(async (e) => {
    console.error(e);
    await prisma.$disconnect();
    process.exit(1);
  });
