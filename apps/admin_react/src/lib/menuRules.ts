/** Menu helpers ported from menu_screen.dart: plate palettes, standard categories, name → category / veg detection, course order. */

/** Plate colours for new dishes, so a menu looks appetising before any photo is uploaded (STYLE.md §6). */
export const platePalettes = [
  ['#D9622B', '#F2C27B', '#4F8A3B'], ['#8A3B1F', '#F5E3C3', '#6FA14A'], ['#6B2E1E', '#E8D2A8', '#3F7D3A'], ['#E7C27D', '#B9823A', '#5E8F3E'],
  ['#D99A2B', '#8B4A2B', '#F2E4C2'], ['#F2B33D', '#F7D27A', '#E07A2E'], ['#EFE8D6', '#CFE3C2', '#6E9B4E'], ['#6E2A12', '#9C4520', '#E9C46A'],
];

/** Standard 40 professional categories from Restaurant_POS_Menu_With_Serving_Sizes.xlsx */
export const standardMenuCategories = [
  'Packaged Beverages', 'Cold Beverages', 'Fresh Juices', 'Shakes & Smoothies', 'Mocktails', 'Hot Beverages',
  'Soups', 'Veg Starters', 'Non-Veg Starters', 'Tandoori Items', 'Chinese Starters', 'Snacks', 'Street Food / Chaat',
  'Rolls & Wraps', 'Salads', 'Veg Main Course', 'Paneer Special', 'Dal Special', 'Non-Veg Main Course', 'Seafood',
  'Chinese Main Course', 'South Indian', 'North Indian', 'Continental', 'Italian', 'Fast Food', 'Breakfast',
  'Thali / Combos', 'Kids Menu', 'Jain Food', 'Chef Specials', 'Indian Breads', 'Rice', 'Biryani', 'Pulao',
  'Raita & Curd', 'Papad & Accompaniments', 'Desserts', 'Cakes & Bakery', 'Ice Cream',
];

export const popularExcelCategories = ['Packaged Beverages', 'Cold Beverages', 'Hot Beverages', 'Fast Food', 'Biryani', 'Veg Main Course', 'Paneer Special', 'Dal Special', 'Desserts'];

const has = (re: RegExp, s: string) => re.test(s);

/** Smart classification of a dish name into the 40 standard categories. */
export function detectMenuCategory(rawName: string): string | null {
  const name = rawName.trim().toLowerCase();
  if (!name) return null;
  if (has(/\b(coke|cola|pepsi|sprite|fanta|thums\s*up|limca|mirinda|mountain\s*dew|red\s*bull|monster|sting|kinley|aquafina|bisleri|water\s*bottle|packaged\s*water|soda\s*can|ginger\s*ale|tonic\s*water|appy|beverage|can|tin)\b/, name)) return 'Packaged Beverages';
  if (has(/\b(cold\s*coffee|iced\s*tea|iced\s*latte|iced\s*americano|lassi|chaas|buttermilk|lime\s*soda|lime\s*water|nimbu\s*pani|jaljeera|masala\s*soda)\b/, name)) return 'Cold Beverages';
  if (has(/\b(shake|smoothie|frappe)\b/, name)) return 'Shakes & Smoothies';
  if (has(/\b(juice|fresh\s*juice|mosambi|orange\s*juice|watermelon\s*juice|pineapple\s*juice|apple\s*juice)\b/, name)) return 'Fresh Juices';
  if (has(/\b(mojito|mocktail|colada|cooler|punch|blue\s*lagoon)\b/, name)) return 'Mocktails';
  if (has(/\b(tea|chai|coffee|espresso|cappuccino|latte|hot\s*chocolate|kahwa|americano)\b/, name)) return 'Hot Beverages';
  if (has(/\b(ice\s*cream|sundae|scoop|kulfi)\b/, name)) return 'Ice Cream';
  if (has(/\b(pastry|cake|muffin|cupcake|croissant|donut|doughnut)\b/, name)) return 'Cakes & Bakery';
  if (has(/\b(gulab\s*jamun|rasmalai|rasgulla|halwa|kheer|jalebi|brownie|mousse|pudding|sweet)\b/, name)) return 'Desserts';
  if (has(/\b(soup|shorba|broth)\b/, name)) return 'Soups';
  if (has(/\b(biryani)\b/, name)) return 'Biryani';
  if (has(/\b(pulao|pilaf)\b/, name)) return 'Pulao';
  if (has(/\b(rice|jeera\s*rice|steamed\s*rice|fried\s*rice)\b/, name)) return name.includes('fried') ? 'Chinese Main Course' : 'Rice';
  if (has(/\b(paneer)\b/, name)) {
    if (name.includes('tikka') || name.includes('chilli')) return 'Veg Starters';
    if (name.includes('pizza')) return 'Italian';
    if (name.includes('burger')) return 'Fast Food';
    if (name.includes('roll') || name.includes('wrap')) return 'Rolls & Wraps';
    return 'Paneer Special';
  }
  if (has(/\b(dal|makhani|tadka|sambar)\b/, name)) return 'Dal Special';
  if (has(/\b(roti|naan|paratha|kulcha|puri|chapati|phulka|rumali)\b/, name)) return 'Indian Breads';
  if (has(/\b(dosa|idli|vada|uttapam|appam|pongal)\b/, name)) return 'South Indian';
  if (has(/\b(pizza|pasta|lasagna|lasagne|mac\s*and\s*cheese|bruschetta|garlic\s*bread|spaghetti|penne)\b/, name)) return 'Italian';
  if (has(/\b(burger|fries|french\s*fries|sandwich|nuggets|nachos|wedges)\b/, name)) return 'Fast Food';
  if (has(/\b(chaat|pani\s*puri|golgappa|sev\s*puri|bhel|papdi|bhelpuri|tikki)\b/, name)) return 'Street Food / Chaat';
  if (has(/\b(roll|wrap|kathi|frankie)\b/, name)) return 'Rolls & Wraps';
  if (has(/\b(thali|combo|platter|meal)\b/, name)) return 'Thali / Combos';
  if (has(/\b(salad|kachumber)\b/, name)) return 'Salads';
  if (has(/\b(raita|curd|dahi|tzatziki)\b/, name)) return 'Raita & Curd';
  if (has(/\b(papad|chutney|pickle|achar)\b/, name)) return 'Papad & Accompaniments';
  if (has(/\b(fish|prawn|crab|lobster|squid|seafood|surmai|pomfret)\b/, name)) return 'Seafood';
  if (has(/\b(chicken|mutton|egg|keema|lamb|meat|tandoori\s*chicken|lollipop|seekh)\b/, name)) {
    return has(/\b(tikka|kebab|65|lollipop|dry|chilli|fry|starter|wings)\b/, name) ? 'Non-Veg Starters' : 'Non-Veg Main Course';
  }
  if (has(/\b(manchurian|noodles|hakka|chowmein|schezwan|spring\s*roll|dimsum|momos)\b/, name)) {
    if (name.includes('noodles') || name.includes('gravy') || name.includes('rice')) return 'Chinese Main Course';
    return 'Chinese Starters';
  }
  if (has(/\b(samosa|kachori|pakora|bhajia|cutlet|poha|upma)\b/, name)) return 'Snacks';
  return null;
}

export const detectMenuIsVeg = (rawName: string) =>
  !/\b(chicken|mutton|egg|fish|prawn|crab|lobster|squid|meat|keema|lamb|pork|beef|bacon|seafood|non-veg|nonveg)\b/.test(rawName.trim().toLowerCase());

/** Veg hint from a category name: "Non-Veg Main Course" → false, "Veg Starters" → true, "Desserts" → null. */
export function categoryIsVeg(rawName: string): boolean | null {
  const name = rawName.trim().toLowerCase();
  if (/non[\s-]?veg|\b(chicken|mutton|fish|seafood|egg|meat|kebab|keema|prawn)\b/.test(name)) return false;
  if (/\b(veg|vegetarian|paneer|dal)\b/.test(name)) return true;
  return null;
}

/**
 * Where a category sits on the menu (the serving order): 0 water, 1 soft & cold drinks, 2 other drinks, 3 soups & starters,
 * 4 curries & mains (anything unrecognised), 5 breads, 6 rice & biryani, 7 accompaniments, 8 desserts, 9 ice cream.
 */
export function courseRank(category: string): number {
  const n = category.toLowerCase();
  const any = (words: string[]) => words.some((w) => n.includes(w));
  if (any(['ice cream', 'icecream', 'kulfi', 'sundae', 'gelato'])) return 9;
  if (any(['water', 'packaged'])) return 0;
  if (any(['soft drink', 'cold beverage', 'cold drink', 'soda', 'cola', 'coke', 'pepsi', 'sprite', 'aerated'])) return 1;
  if (any(['beverage', 'drink', 'juice', 'shake', 'smoothie', 'mocktail', 'cocktail', 'lassi', 'chaas', 'tea', 'chai', 'coffee', 'cooler'])) return 2;
  if (any(['soup', 'shorba', 'broth', 'starter', 'appetiser', 'appetizer', 'tandoor', 'kebab', 'snack', 'chaat', 'street', 'roll', 'wrap', 'salad', 'momo'])) return 3;
  if (any(['bread', 'naan', 'roti', 'paratha', 'kulcha'])) return 5;
  if (any(['rice', 'biryani', 'pulao', 'khichdi'])) return 6;
  if (any(['raita', 'curd', 'papad', 'accompaniment', 'pickle', 'chutney'])) return 7;
  if (any(['dessert', 'sweet', 'cake', 'bakery', 'pastry', 'mithai', 'halwa', 'kheer', 'brownie', 'pudding', 'custard'])) return 8;
  return 4;
}

/** Stable sort by course: same-course categories keep their relative order (Array.prototype.sort is stable). */
export const sortByCourse = <T,>(cats: T[], name: (c: T) => string): T[] => [...cats].sort((a, b) => courseRank(name(a)) - courseRank(name(b)));

export const servingUnits = ['ml', 'l', 'g', 'kg', 'piece', 'plate', 'bowl', 'glass', 'cup', 'portion', 'bottle', 'can', 'packet'];
export const portionLabels = ['half', 'full'];

/**
 * Concise short prefix from a restaurant name: "Demo Dhaba" → "DD-", "The Spice Route" → "TSR-", "Chai" → "CHAI-".
 * Falls back to the tenant code, then "RST-".
 */
export function restaurantShortPrefix(name?: string | null, fallbackCode?: string | null): string {
  if (name && name.trim()) {
    const words = name.trim().split(/\s+/).map((w) => w.replace(/[^A-Za-z0-9]/g, '')).filter(Boolean);
    if (words.length >= 2) {
      const initials = words.slice(0, 4).map((w) => w[0].toUpperCase()).join('');
      if (initials) return `${initials}-`;
    } else if (words.length === 1) {
      const clean = words[0].toUpperCase();
      return clean.length <= 4 ? `${clean}-` : `${clean.substring(0, 3)}-`;
    }
  }
  if (fallbackCode && fallbackCode.trim()) {
    const clean = fallbackCode.trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (clean) return `${clean}-`;
  }
  return 'RST-';
}

/** SKU suggestion from a name with a prefix ("DD-" + "Butter Chicken" → "DD-BC01"). */
export function deriveCode(rawName: string, prefix: string): string {
  const raw = rawName.trim();
  if (!raw) return `${prefix}001`;
  const words = raw.split(/\s+/).map((w) => w.replace(/[^A-Za-z0-9]/g, '')).filter(Boolean);
  if (words.length === 0) return `${prefix}001`;
  let sfx: string;
  if (words.length === 1) {
    const w = words[0].toUpperCase();
    sfx = w.length <= 8 ? w : w.substring(0, 6);
  } else {
    const initials = words.map((w) => w[0].toUpperCase()).join('');
    if (initials.length >= 2 && initials.length <= 4) sfx = `${initials}01`;
    else {
      const w = words[0].toUpperCase();
      sfx = w.length <= 5 ? w : w.substring(0, 5);
    }
  }
  return `${prefix}${sfx}`;
}
