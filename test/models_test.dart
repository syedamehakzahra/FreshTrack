import 'package:flutter_test/flutter_test.dart';
import 'package:freshtrack/models/recipe.dart';
import 'package:freshtrack/models/waste_log.dart';

void main() {
  group('Recipe Model Tests', () {
    test('Correctly parses full meal JSON with ingredients', () {
      final json = {
        'idMeal': '52772',
        'strMeal': 'Teriyaki Chicken Casserole',
        'strMealThumb': 'https://www.themealdb.com/images/media/meals/wvpsxx1468256321.jpg',
        'strCategory': 'Chicken',
        'strArea': 'Japanese',
        'strInstructions': 'Cook the chicken and vegetables...',
        'strIngredient1': 'Chicken',
        'strMeasure1': '3/4 cup',
        'strIngredient2': 'Soy Sauce',
        'strMeasure2': '1/2 cup',
        'strIngredient3': '',
        'strMeasure3': '',
      };

      final recipe = Recipe.fromMealJson(json);

      expect(recipe.id, '52772');
      expect(recipe.title, 'Teriyaki Chicken Casserole');
      expect(recipe.category, 'Chicken');
      expect(recipe.area, 'Japanese');
      expect(recipe.ingredients.length, 2);
      expect(recipe.ingredients.first, 'Chicken (3/4 cup)');
    });

    test('Correctly parses filter meal JSON', () {
      final json = {
        'idMeal': '52771',
        'strMeal': 'Spicy Arrabiata Penne',
        'strMealThumb': 'https://www.themealdb.com/images/media/meals/ustsqw1468250014.jpg',
      };

      final recipe = Recipe.fromFilterJson(json);

      expect(recipe.id, '52771');
      expect(recipe.title, 'Spicy Arrabiata Penne');
      expect(recipe.thumbnail, contains('themealdb'));
    });
  });

  group('WasteLog Model Tests', () {
    test('Correctly converts to Map for Firestore storage', () {
      final now = DateTime.now();
      final log = WasteLog(
        id: 'test_1',
        foodName: 'Apples',
        category: 'Fruits',
        quantity: 3,
        action: 'consumed',
        timestamp: now,
      );

      final map = log.toMap();

      expect(map['foodName'], 'Apples');
      expect(map['category'], 'Fruits');
      expect(map['quantity'], 3);
      expect(map['action'], 'consumed');
    });
  });
}
