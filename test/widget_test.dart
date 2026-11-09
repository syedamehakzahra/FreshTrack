import 'package:flutter_test/flutter_test.dart';
import 'package:freshtrack/models/food_item.dart';

void main() {
  group('FoodItem Model Tests', () {
    test('Calculates daysLeft and status correctly for fresh items', () {
      final futureDate = DateTime.now().add(const Duration(days: 5));
      final item = FoodItem(
        id: '1',
        name: 'Milk',
        category: 'Dairy',
        quantity: 2,
        expiryDate: futureDate,
      );

      expect(item.status, 'Fresh');
      expect(item.daysLeft, greaterThanOrEqualTo(4));
    });

    test('Calculates status correctly for expiring soon items', () {
      final soonDate = DateTime.now().add(const Duration(days: 2));
      final item = FoodItem(
        id: '2',
        name: 'Bread',
        category: 'Bakery',
        quantity: 1,
        expiryDate: soonDate,
      );

      expect(item.status, 'Expiring soon');
    });

    test('Calculates status correctly for expired items', () {
      final pastDate = DateTime.now().subtract(const Duration(days: 1));
      final item = FoodItem(
        id: '3',
        name: 'Yogurt',
        category: 'Dairy',
        quantity: 1,
        expiryDate: pastDate,
      );

      expect(item.status, 'Expired');
      expect(item.daysLeft, lessThan(0));
    });
  });
}
