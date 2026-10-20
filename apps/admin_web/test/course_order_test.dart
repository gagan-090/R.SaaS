import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/screens/console/menu_screen.dart';

void main() {
  test('categories sort into the serving order; same-course categories keep their order', () {
    final cats = ['Ice Cream', 'Mains', 'Soft Drinks', 'Desserts', 'Indian Breads', 'Chinese Starters', 'Mocktails', 'Biryani', 'Soups', 'Water', 'Chef Specials', 'Raita & Curd', 'Paneer Special', 'Curries'];
    expect(sortByCourse(cats, (c) => c), [
      'Water', 'Soft Drinks', 'Mocktails', 'Chinese Starters', 'Soups', 'Mains', 'Chef Specials', 'Paneer Special', 'Curries', 'Indian Breads', 'Biryani', 'Raita & Curd', 'Desserts', 'Ice Cream',
    ]);
    expect(courseRank('Packaged Beverages'), 0);
    expect(courseRank('Cold Beverages'), 1);
    expect(courseRank('Tandoori Items'), 3);
    expect(courseRank('Ice Cream'), 9);
  });

  test('the standard categories are already in serving order', () {
    expect(standardMenuCategories.length, 40);
    expect(sortByCourse(standardMenuCategories, (c) => c), standardMenuCategories);
  });
}
