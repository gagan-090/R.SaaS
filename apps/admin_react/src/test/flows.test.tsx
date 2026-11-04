import { describe, expect, test, vi } from 'vitest';
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { FixtureApi, fixture } from './fixtureApi';

/** Starts the whole app fresh (new auth state, new caches) at a hash route, against the fixture API. */
async function boot(hash: string, opts: { signedIn?: boolean; setup?: (fx: FixtureApi) => void } = {}) {
  vi.resetModules();
  window.location.hash = hash;
  if (opts.signedIn) window.sessionStorage.setItem('house-plating.session.v1', 'r1');
  const fx = new FixtureApi().install();
  opts.setup?.(fx);
  const { default: App } = await import('../App');
  render(<App />);
  return { fx, user: userEvent.setup() };
}

const owner = {
  type: 'user',
  id: 'u-owner',
  name: 'Demo Owner',
  email: 'owner@demo.test',
  roles: ['owner'],
  permissions: ['menu.read', 'menu.publish', 'restaurant.profile.read', 'restaurant.profile.manage', 'reports.read', 'staff.read', 'staff.manage', 'floor.read', 'floor.manage', 'device.manage', 'audit.read'],
  tenant: { name: 'Demo Dhaba', code: 'R000001' },
};
const overview = {
  restaurant: { name: 'Demo Dhaba', gstin: null, address: null },
  license: { state: 'active', planName: 'Premium', endsAt: '2026-12-01T00:00:00Z', features: ['menu', 'tables'] },
  counts: { items: 0, categories: 1, tables: 0, staff: 1 },
  hub: null,
  branches: [{ id: 'b1', name: 'Main' }],
  branding: null,
};

const dashboard = {
  kpis: { salesPaise: 1245000, bills: 31, avgBillPaise: 40161, orders: 33, tipsPaise: 5000, taxesPaise: 59286, discountsPaise: 2000, dineInPaise: 1000000, takeawayPaise: 245000, dineInBills: 24, takeawayBills: 7, reversals: { amountPaise: 18000, count: 1 }, adjustments: { amountPaise: 0, count: 0 } },
  change: { salesPct: 12, billsPct: -3 },
  previous: { salesPaise: 1111600 },
  live: { openTables: 3, takeaways: 1, unpaidBills: 2, unpaidPaise: 84000 },
  hourly: Array.from({ length: 24 }, (_, h) => ({ hour: h, salesPaise: h === 20 ? 500000 : h === 13 ? 300000 : 0, bills: h === 20 ? 10 : 0 })),
  series: [],
  busiestHour: 20,
  byMode: { cash: 445000, upi: 600000, card: 200000 },
  byCategory: [{ name: 'Main Course', qty: 20, amountPaise: 800000 }],
  reversals: { reasons: [{ reason: 'Wrong dish', count: 1 }] },
  topItems: [{ name: 'Dal Makhani', category: 'Main Course', qty: 12, amountPaise: 300000 }],
  byWaiter: [{ name: 'Asha', bills: 12, salesPaise: 500000, tipsPaise: 2000 }],
  recentBills: [{ id: 'bill1', invoiceNo: 'BR01/26-27/000001', where: 'Table 4', waiter: 'Asha', closedAt: '2026-10-23T14:12:00Z', status: 'paid', totalPaise: 42000 }],
};
const bill = {
  invoiceNo: 'BR01/26-27/000001', status: 'paid', where: 'Table 4', waiter: 'Asha', closedAt: '2026-10-23T14:12:00Z',
  lines: [
    { qty: 2, name: 'Dal Makhani', amountPaise: 40000, status: 'sent' },
    { qty: 1, name: 'Paneer Tikka', amountPaise: 18000, status: 'reversed', reversalReason: 'Wrong dish' },
  ],
  totals: { subtotalPaise: 40000, discountPaise: 0, cgstPaise: 1000, sgstPaise: 1000, tipPaise: 0, roundOffPaise: 0, totalPaise: 42000 },
  payments: [{ mode: 'upi', amountPaise: 42000, changePaise: 0 }],
  tips: [],
  adjustments: [],
};

describe('sign in (port of admin_web_test.dart P1/P2)', () => {
  test('password then MFA code lands on the Super Admin dashboard', async () => {
    const { fx, user } = await boot('#/login');
    await user.type(await screen.findByTestId('login-email'), 'admin@example.com');
    await user.type(screen.getByTestId('login-password'), 'correct horse');
    await user.click(screen.getByTestId('login-submit'));
    expect(fx.where('POST', '/auth/login')[0].body).toEqual({ email: 'admin@example.com', password: 'correct horse' });

    await user.type(await screen.findByTestId('mfa-code'), '123456');
    await user.click(screen.getByTestId('mfa-verify'));
    expect(await screen.findByRole('heading', { name: 'Dashboard' })).toBeInTheDocument();
    const verify = fx.where('POST', '/auth/mfa/verify')[0].body;
    expect(verify.code).toBe('123456');
    expect(verify.challengeToken).toBe(fixture('POST_auth_login.mfa_required.json').challengeToken);
    // platform navigation, not the restaurant console
    expect(screen.getAllByTestId('nav-Restaurants').length).toBeGreaterThan(0);
    expect(screen.queryByTestId('nav-Menu')).toBeNull();
    // the refresh token survives a reload in this tab only
    expect(window.sessionStorage.getItem('house-plating.session.v1')).toBe('<refreshToken>');
  });

  test('wrong password shows the server message and the new-owner hint', async () => {
    const { user } = await boot('#/login', { setup: (fx) => fx.set('POST /auth/login', 401, { code: 'invalid_credentials', message: 'Email or password is wrong' }) });
    await user.type(await screen.findByTestId('login-email'), 'a@b.co');
    await user.type(screen.getByTestId('login-password'), 'nope');
    await user.click(screen.getByTestId('login-submit'));
    expect(await screen.findByTestId('login-error')).toHaveTextContent('Email or password is wrong');
    expect(screen.getByTestId('login-hint')).toBeInTheDocument();
  });

  test('a signed-out visitor is sent to sign in; emailed links still open', async () => {
    await boot('#/plans');
    expect(await screen.findByRole('heading', { name: 'Sign in' })).toBeInTheDocument();
    expect(window.location.hash).toBe('#/login');
  });
});

describe('Super Admin console', () => {
  test('restaurants list → detail → suspend requires a reason and sends it', async () => {
    const { fx, user } = await boot('#/restaurants', { signedIn: true });
    const rows = await screen.findAllByTestId('row-R000537');
    await user.click(rows[rows.length - 1]);
    expect(await screen.findByRole('heading', { name: 'Spice Route' })).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Suspend' }));
    const dialog = await screen.findByRole('dialog');
    const confirmBtn = within(dialog).getByTestId('reason-confirm');
    expect(confirmBtn).toBeDisabled(); // a reason of at least 3 characters is required
    await user.type(within(dialog).getByTestId('reason-field'), 'Payment overdue');
    await user.click(confirmBtn);
    await waitFor(() => expect(fx.where('POST', '/status')).toHaveLength(1));
    expect(fx.where('POST', '/status')[0].body).toEqual({ action: 'suspend', reason: 'Payment overdue' });
  });

  test('MFA reset asks for a reason, then step-up, and sends the step-up token', async () => {
    const { fx, user } = await boot('#/admins', { signedIn: true });
    await user.click(await screen.findByTestId('admin-actions-admin-mv6eegx8-d2cd61@example.test'));
    await user.click(await screen.findByRole('menuitem', { name: 'Reset MFA…' }));
    await user.type(await screen.findByTestId('reason-field'), 'Lost phone, identity checked');
    await user.click(screen.getByTestId('reason-confirm'));
    await user.type(await screen.findByTestId('stepup-password'), 'my password');
    await user.type(screen.getByTestId('stepup-code'), '654321');
    await user.click(screen.getByTestId('stepup-verify'));
    await waitFor(() => expect(fx.where('POST', '/mfa/reset')).toHaveLength(1));
    expect(fx.where('POST', '/auth/step-up')[0].body).toEqual({ password: 'my password', code: '654321' });
    const reset = fx.where('POST', '/mfa/reset')[0];
    expect(reset.body).toEqual({ reason: 'Lost phone, identity checked' });
    expect(reset.headers['x-step-up-token']).toBe(fixture('POST_auth_step_up.json').stepUpToken);
  });

  test('Admins sub-menu lists admin types; status filter sits on top', async () => {
    const { user } = await boot('#/admins?role=Onboarding%20Admin', { signedIn: true });
    expect(await screen.findByTestId('admins-title')).toHaveTextContent('Onboarding Admin');
    expect(screen.getAllByTestId('admin-status-filter').length).toBeGreaterThan(0);
    await user.click(screen.getAllByTestId('nav-admins-all')[0]);
    expect(await screen.findByTestId('admins-title')).toHaveTextContent('Platform admins');
  });

  test('changing a plan price sends integer paise', async () => {
    const { fx, user } = await boot('#/plans', { signedIn: true });
    const edits = await screen.findAllByRole('button', { name: 'Edit' });
    await user.click(edits[0]);
    const price = await screen.findByTestId('plan-price');
    await user.clear(price);
    await user.type(price, '1,249.50');
    await user.click(screen.getByTestId('save-plan'));
    await waitFor(() => expect(fx.where('PATCH', '/plans/')).toHaveLength(1));
    const body = fx.where('PATCH', '/plans/')[0].body;
    expect(body.pricePaise).toBe(124950);
    expect(Number.isInteger(body.yearlyPricePaise)).toBe(true);
  });

  test('audit log lists events in words', async () => {
    await boot('#/audit', { signedIn: true });
    expect((await screen.findAllByText('Restaurant status changed')).length).toBeGreaterThan(0);
  });
});

describe('restaurant console', () => {
  test('owner lands on the restaurant dashboard; range switch, every section, bill drill-down; no platform pages', async () => {
    const { fx, user } = await boot('#/', {
      signedIn: true,
      setup: (fx) =>
        fx
          .set('GET /me', 200, owner)
          .set('GET /tenant/overview', 200, overview)
          .set('GET /tenant/dashboard', 200, dashboard)
          .set('GET /tenant/bills/bill1', 200, bill),
    });
    expect(await screen.findByText(/Get ready for service/)).toBeInTheDocument();
    expect(window.location.hash).toBe('#/console');
    expect(screen.queryByTestId('nav-Restaurants')).toBeNull();
    expect(screen.getAllByTestId('nav-Menu').length).toBeGreaterThan(0);
    expect(screen.getByTestId('kpi-sales')).toHaveTextContent('₹12,450');
    expect(screen.getByTestId('live-strip')).toHaveTextContent('tables seated');
    for (const s of ['How guests paid', 'Dine-in vs takeaway', 'Sales by category', 'Staff performance', 'Recent bills']) expect(screen.getByText(s)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: '7 days' }));
    await waitFor(() => expect(fx.where('GET', '/tenant/dashboard').some((c) => c.query.get('range') === '7d')).toBe(true));
    await user.click(await screen.findByTestId('recent-BR01/26-27/000001'));
    const dlg = await screen.findByRole('dialog');
    expect(await within(dlg).findByText('Reversed: Wrong dish')).toBeInTheDocument();
    expect(within(dlg).getAllByText('₹420')).toHaveLength(2); // the total and the UPI payment
  });

  test('menu: a dish price in rupees is sent as paise, with a SKU from the restaurant name', async () => {
    const { fx, user } = await boot('#/console/menu', {
      signedIn: true,
      setup: (fx) =>
        fx
          .set('GET /me', 200, owner)
          .set('GET /tenant/overview', 200, overview)
          .set('GET /menu/categories', 200, [{ id: 'c1', name: 'Main Course', active: true }])
          .set('GET /menu/items', 200, [])
          .set('GET /tax-rules', 200, [{ id: 't1', name: 'GST 5%', rateBp: 500 }])
          .set('POST /menu/items', 200, { id: 'i1' }),
    });
    await user.click(await screen.findByTestId('add-dish'));
    await user.type(await screen.findByTestId('dish-name'), 'Paneer Butter Masala');
    await user.type(screen.getByTestId('size-price-0'), '249.5');
    await user.click(screen.getByTestId('save-dish'));
    await waitFor(() => expect(fx.where('POST', '/menu/items')).toHaveLength(1));
    const body = fx.where('POST', '/menu/items')[0].body;
    expect(body.variants[0].pricePaise).toBe(24950);
    expect(body.code).toBe('DD-PBM01');
    expect(body.categoryId).toBe('c1');
    expect(body.isVeg).toBe(true);
  });

  test('employee signs in with email + PIN and sees only what a chef may use', async () => {
    const chef = {
      type: 'user',
      id: 'u-chef',
      name: 'Ravi Kumar',
      email: 'ravi@demo.test',
      roles: ['chef'],
      permissions: ['order.read', 'kds.read', 'kds.update', 'inventory.read', 'inventory.consume', 'inventory.request', 'menu.read'],
      tenant: { name: 'Demo Dhaba', code: 'R000001' },
    };
    const { fx, user } = await boot('#/login?mode=employee', {
      setup: (fx) =>
        fx
          .set('POST /auth/pin-login', 200, { status: 'ok', accessToken: 'a', refreshToken: 'r' })
          .set('GET /me', 200, chef)
          .set('GET /records/live-orders', 200, [])
          .set('GET /inventory/alerts', 200, { low: [{ name: 'Onion', sku: 'ON', stock: 2, unit: 'kg' }], expiring: [], negative: [] }),
    });
    expect(await screen.findByText('Employees: your work email and PIN')).toBeInTheDocument();
    await user.type(screen.getByTestId('login-email'), 'ravi@demo.test');
    await user.type(screen.getByTestId('login-pin'), '24a6813'); // letters are dropped
    await user.click(screen.getByTestId('login-submit'));
    expect(fx.where('POST', '/auth/pin-login')[0].body).toEqual({ email: 'ravi@demo.test', pin: '246813' });
    expect(await screen.findByRole('heading', { name: 'Hello, Ravi' })).toBeInTheDocument();
    expect(await screen.findByText('Kitchen orders')).toBeInTheDocument();
    expect(await screen.findByTestId('home-low-ON')).toBeInTheDocument();
    expect(screen.getAllByTestId('nav-Inventory').length).toBeGreaterThan(0);
    for (const hidden of ['nav-Staff', 'nav-Settings', 'nav-Expenses', 'nav-Restaurants']) expect(screen.queryByTestId(hidden)).toBeNull();
    // a chef has no restaurant.profile.read: the console never asks for the restaurant overview
    expect(fx.where('GET', '/tenant/overview')).toHaveLength(0);
  });

  test('a page outside the plan says so instead of "Something went wrong"', async () => {
    await boot('#/console/settings', {
      signedIn: true,
      setup: (fx) => fx.set('GET /me', 200, owner).set('GET /tenant/overview', 403, { code: 'no_active_plan', message: 'No plan' }).set('GET /tax-rules', 200, []),
    });
    expect(await screen.findByTestId('plan-locked')).toHaveTextContent('Not in your plan');
  });
});

describe('emailed links', () => {
  test('set-PIN link: shows who it is for, checks the rules, then confirms', async () => {
    const { fx, user } = await boot('#/set-pin?token=t1', {
      setup: (fx) => fx.set('POST /auth/pin-link/check', 200, { name: 'Asha', restaurantName: 'Demo Dhaba', purpose: 'invite' }).set('POST /auth/pin-link/complete', 200, { webAccess: true }),
    });
    expect(await screen.findByText('Asha · Demo Dhaba')).toBeInTheDocument();
    await user.type(screen.getByTestId('new-pin'), '123456');
    await user.type(screen.getByTestId('new-pin-again'), '123456');
    await user.click(screen.getByTestId('save-pin'));
    expect(screen.getByTestId('set-pin-error')).toHaveTextContent('run of digits');
    await user.clear(screen.getByTestId('new-pin'));
    await user.clear(screen.getByTestId('new-pin-again'));
    await user.type(screen.getByTestId('new-pin'), '246813');
    await user.type(screen.getByTestId('new-pin-again'), '246813');
    await user.click(screen.getByTestId('save-pin'));
    expect(await screen.findByText('Your PIN is set. Sign in with your email and PIN.')).toBeInTheDocument();
    expect(fx.where('POST', '/pin-link/complete')[0].body).toEqual({ token: 't1', pin: '246813' });
  });

  test('owner opens the verification link, sets a strong password and is told to sign in', async () => {
    const { fx, user } = await boot('#/verify-email?token=tok');
    await user.type(await screen.findByTestId('verify-password'), 'short');
    await user.click(screen.getByTestId('verify-submit'));
    expect(screen.getByTestId('verify-error')).toHaveTextContent('at least 8 characters');
    await user.clear(screen.getByTestId('verify-password'));
    await user.type(screen.getByTestId('verify-password'), 'Masala2026x');
    await user.type(screen.getByTestId('verify-password2'), 'Masala2026x');
    await user.click(screen.getByTestId('verify-submit'));
    expect(await screen.findByText('Your restaurant is ready')).toBeInTheDocument();
    expect(screen.getByText(/Restaurant code R000537/)).toBeInTheDocument();
    expect(fx.where('POST', '/verify-email')[0].body).toEqual({ token: 'tok', password: 'Masala2026x' });
  });
});
