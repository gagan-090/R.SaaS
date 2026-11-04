import { describe, expect, test } from 'vitest';
import { formatPaise, qtyText, rupees } from '../lib/format';
import { parseRupees } from '../lib/money';
import { pinProblem } from '../lib/pin';
import { auditActionLabel, auditActor, auditChanges, featureGroups, restaurantStatusLabel, restaurantStatusTone } from '../lib/labels';
import { categoryIsVeg, courseRank, deriveCode, detectMenuCategory, detectMenuIsVeg, restaurantShortPrefix, sortByCourse, standardMenuCategories } from '../lib/menuRules';
import { arrangeChairs, floorOverlaps, tableFromJson } from '../lib/floor';
import { inkOn, luminance, onColor } from '../state/brand';
import { redirectFor } from '../shell/nav';
import { parseQuickRows } from '../screens/console/MenuScreen';

describe('money', () => {
  test('paise format with Indian grouping and no floats', () => {
    expect(formatPaise(167000)).toBe('₹1,670.00');
    expect(formatPaise(10000000)).toBe('₹1,00,000.00');
    expect(formatPaise(12345678)).toBe('₹1,23,456.78');
    expect(formatPaise(-50)).toBe('−₹0.50');
    expect(rupees(24900)).toBe('₹249');
    expect(rupees(24950)).toBe('₹249.50');
  });
  test('rupees typed by people become integer paise', () => {
    expect(parseRupees('249')).toBe(24900);
    expect(parseRupees('1,249.5')).toBe(124950);
    expect(parseRupees('0.07')).toBe(7);
    expect(parseRupees('19.99')).toBe(1999); // 19.99 * 100 in floats is 1998.9999…
    expect(parseRupees('12.345')).toBeNull();
    expect(parseRupees('abc')).toBeNull();
    expect(parseRupees('')).toBeNull();
  });
  test('quantities drop trailing zeros', () => {
    expect(qtyText(2, 'kg')).toBe('2 kg');
    expect(qtyText(0.25, 'l')).toBe('0.25 l');
  });
});

describe('PIN rules match the server', () => {
  test.each([
    ['12345', 'PIN must be 6 to 8 digits'],
    ['111111', 'PIN cannot be the same digit repeated'],
    ['123456', 'PIN cannot be a run of digits like 123456'],
    ['987654', 'PIN cannot be a run of digits like 123456'],
    ['890123', 'PIN cannot be a run of digits like 123456'],
    ['246813', null],
  ])('%s', (pin, problem) => expect(pinProblem(pin)).toBe(problem));
});

describe('labels read as words, never codes', () => {
  test('audit actions', () => {
    expect(auditActionLabel('auth.login')).toBe('Signed in');
    expect(auditActionLabel('expense.created')).toBe('Expense added');
    expect(auditActionLabel('inventory.product_updated')).toBe('Stock product changed');
    expect(auditActionLabel('widget.thing_voided')).toBe('Thing cancelled');
  });
  test('audit details show fields and values, not ids', () => {
    const changes = auditChanges({ action: 'restaurant.status_changed', before: { status: 'active', tenantId: 'x' }, after: { status: 'suspended', tenantId: 'x' } });
    expect(changes).toEqual([['Status', 'active → suspended']]);
    expect(auditChanges({ action: 'platform.admin.roles_changed', before: [{ name: 'A' }], after: [{ name: 'B' }, { name: 'C' }] })).toEqual([['Roles', 'A → B, C']]);
    expect(auditChanges({ action: 'x', before: null, after: { menuItemId: '1', name: 'Dal', isVeg: true } })).toEqual([
      ['Name', 'Dal'],
      ['Is Veg', 'Yes'],
    ]);
    expect(auditActor({ actorName: 'Demo Owner', actorRole: 'owner' })).toBe('Demo Owner (Owner)');
    expect(auditActor({ actorType: 'device' })).toBe('A device');
  });
  test('an active restaurant without a plan is not plain "Active"', () => {
    expect(restaurantStatusLabel('active', false)).toBe('Active · no plan');
    expect(restaurantStatusTone('active', false)).toBe('saffron');
    expect(restaurantStatusLabel('active', true)).toBe('Active');
  });
  test('every server feature is in the plan editor', () => {
    const all = featureGroups.flatMap(([, items]) => items.map(([k]) => k));
    for (const f of ['staff_portal', 'roles.custom', 'floor.editor', 'import.excel', 'expenses', 'branding', 'inventory']) expect(all).toContain(f);
  });
  test('category names hint veg / non-veg', () => {
    expect(categoryIsVeg('Non-Veg Main Course')).toBe(false);
    expect(categoryIsVeg('Veg Starters')).toBe(true);
    expect(categoryIsVeg('Desserts')).toBeNull();
  });
});

describe('menu rules', () => {
  test('serving order; same-course categories keep their order', () => {
    const cats = ['Desserts', 'Biryani', 'Veg Starters', 'Water', 'Paneer Special', 'Soups', 'Indian Breads', 'Ice Cream', 'Cold Beverages'];
    expect(sortByCourse(cats, (c) => c)).toEqual(['Water', 'Cold Beverages', 'Veg Starters', 'Soups', 'Paneer Special', 'Indian Breads', 'Biryani', 'Desserts', 'Ice Cream']);
    expect(courseRank('Chinese Starters')).toBe(3);
    expect(standardMenuCategories).toHaveLength(40);
  });
  test('dish names suggest a category and veg', () => {
    expect(detectMenuCategory('Coke 500ml')).toBe('Packaged Beverages');
    expect(detectMenuCategory('Paneer Tikka')).toBe('Veg Starters');
    expect(detectMenuCategory('Chicken 65')).toBe('Non-Veg Starters');
    expect(detectMenuCategory('Butter Chicken')).toBe('Non-Veg Main Course');
    expect(detectMenuIsVeg('Chicken Biryani')).toBe(false);
    expect(detectMenuIsVeg('Veg Biryani')).toBe(true);
  });
  test('short prefix and SKU from the restaurant name', () => {
    expect(restaurantShortPrefix('Demo Dhaba')).toBe('DD-');
    expect(restaurantShortPrefix('The Spice Route')).toBe('TSR-');
    expect(restaurantShortPrefix("McDonald's")).toBe('MCD-');
    expect(restaurantShortPrefix('Chai')).toBe('CHAI-');
    expect(restaurantShortPrefix('', 'R000001')).toBe('R000001-');
    expect(restaurantShortPrefix(null, null)).toBe('RST-');
    expect(deriveCode('Butter Chicken', 'DD-')).toBe('DD-BC01');
    expect(deriveCode('Coke', 'DD-')).toBe('DD-COKE');
  });
  test('quick entry parses Excel rows into paise', () => {
    const r = parseQuickRows('Tomato Soup | Veg | 145 | 210\nButter Naan | 50\nChicken Biryani | Non-Veg | Half 180 | Full 320\nBiryani | Mutton Biryani | 400');
    if ('error' in r) throw new Error(r.error);
    expect(r.items[0]).toMatchObject({ name: 'Tomato Soup', isVeg: true, variants: [{ name: 'Half Plate', pricePaise: 14500 }, { name: 'Full Plate', pricePaise: 21000, isDefault: true }] });
    expect(r.items[1]).toMatchObject({ name: 'Butter Naan', pricePaise: 5000 });
    expect(r.items[2]).toMatchObject({ isVeg: false, variants: [{ name: 'Half', pricePaise: 18000 }, { name: 'Full', pricePaise: 32000 }] });
    expect(r.items[3]).toMatchObject({ name: 'Mutton Biryani', categoryName: 'Biryani', pricePaise: 40000 });
    expect(parseQuickRows('Dal | cheap')).toHaveProperty('error');
  });
});

describe('floor plan', () => {
  test('chairs spread around round and along long tables', () => {
    expect(arrangeChairs('round', 80, 80, 4)).toHaveLength(4);
    const rect = arrangeChairs('rect', 140, 80, 6);
    expect(rect.filter((c) => c.y < 0)).toHaveLength(3);
    expect(rect.filter((c) => c.y > 0)).toHaveLength(3);
    expect(arrangeChairs('rect', 140, 80, 7)).toHaveLength(7);
  });
  test('overlaps warn by name', () => {
    const a = tableFromJson({ name: '1', x: 100, y: 100 }), b = tableFromJson({ name: '2', x: 130, y: 100 }), c = tableFromJson({ name: '3', x: 400, y: 400 });
    expect(floorOverlaps([a, b, c])).toEqual([['1', '2']]);
  });
});

describe('branding', () => {
  test('brand ink keeps 4.5:1 contrast on white and on dark', () => {
    const contrast = (a: string, b: string) => {
      const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
      return (x + 0.05) / (y + 0.05);
    };
    expect(contrast(inkOn('#F0A93B', false), '#FFFFFF')).toBeGreaterThanOrEqual(4.5);
    expect(contrast(inkOn('#212121', true), '#140D0C')).toBeGreaterThanOrEqual(4.5);
    expect(onColor('#F0A93B')).toBe('#16181D');
    expect(onColor('#6B1F2A')).toBe('#FFFFFF');
  });
});

describe('router redirects (same rules as app.dart)', () => {
  test.each([
    [{ kind: 'signedOut' }, '/plans', '/login'],
    [{ kind: 'signedOut' }, '/login', null],
    [{ kind: 'signedOut' }, '/verify-email', null],
    [{ kind: 'signedOut' }, '/set-pin', null],
    [{ kind: 'mfaChallenge' }, '/', '/mfa'],
    [{ kind: 'signedIn', isRestaurant: true }, '/', '/console'],
    [{ kind: 'signedIn', isRestaurant: true }, '/console/menu', null],
    [{ kind: 'signedIn', isRestaurant: false }, '/console', '/'],
    [{ kind: 'signedIn', isRestaurant: false }, '/login', '/'],
    [{ kind: 'signedIn', isRestaurant: false }, '/plans', null],
  ])('%o at %s → %s', (s, path, to) => expect(redirectFor(s, path)).toBe(to));
});
