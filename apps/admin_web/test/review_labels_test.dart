import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/screens/console/menu_screen.dart';
import 'package:rsaas_admin_web/widgets/labels.dart';
import 'package:rsaas_ui_kit/rsaas_ui_kit.dart';

void main() {
  test('audit actions read as words, never codes', () {
    expect(auditActionLabel('expense.created'), 'Expense added');
    expect(auditActionLabel('expense.voided'), 'Expense cancelled');
    expect(auditActionLabel('inventory.product_updated'), 'Stock product changed');
    expect(auditActionLabel('pos.bill.something_new_updated'), 'Something new changed'); // unknown codes still read as words
    expect(auditActionLabel('menu.bulk_import'), 'Bulk import');
  });

  test('audit details show fields and values, not ids or JSON', () {
    final c = auditChanges({'action': 'inventory.product_updated', 'before': {'id': 'x', 'productId': 'p', 'conversionFactor': 1000, 'active': true}, 'after': {'id': 'x', 'productId': 'p', 'conversionFactor': 1, 'active': true}});
    expect(c, [('Conversion Factor', '1000 → 1')]);
  });

  test('an active restaurant without a plan is not shown as plain "Active"', () {
    expect(restaurantStatusLabel('active', hasPlan: false), 'Active · no plan');
    expect(restaurantStatusTone('active', hasPlan: false), HPTone.saffron);
    expect(restaurantStatusLabel('active', hasPlan: true), 'Active');
  });

  test('category names hint veg / non-veg', () {
    expect(categoryIsVeg('Non-Veg Main Course'), isFalse);
    expect(categoryIsVeg('Non Veg Starters'), isFalse);
    expect(categoryIsVeg('Chicken Specials'), isFalse);
    expect(categoryIsVeg('Veg Starters'), isTrue);
    expect(categoryIsVeg('Desserts'), isNull);
  });
}
