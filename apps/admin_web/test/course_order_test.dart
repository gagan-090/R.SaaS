import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_admin_web/screens/console/menu_screen.dart';

void main() {
  test('categories sort into serving order; same-course categories keep their order', () {
    final cats = ['Mains', 'Soft Drinks', 'Desserts', 'Indian Breads', 'Chinese Starters', 'Biryani', 'Soups', 'Chef Specials', 'Raita & Curd', 'Paneer Special'];
    expect(sortByCourse(cats, (c) => c), [
      'Soups', 'Chinese Starters', 'Soft Drinks', 'Mains', 'Chef Specials', 'Paneer Special', 'Indian Breads', 'Biryani', 'Raita & Curd', 'Desserts',
    ]);
    expect(courseRank('Cold Beverages'), 2);
    expect(courseRank('Tandoori Items'), 1);
    expect(courseRank('Ice Cream'), 7);
  });
}
