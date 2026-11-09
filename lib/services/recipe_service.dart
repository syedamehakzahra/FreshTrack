import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/recipe.dart';

class RecipeService {
  static const String _baseUrl = 'https://www.themealdb.com/api/json/v1/1';

  /// Search recipes by meal name or keyword
  Future<List<Recipe>> searchRecipes(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return getRandomRecipes(count: 6);
    }

    final uri = Uri.parse('$_baseUrl/search.php?s=$trimmed');
    final response = await http.get(uri);

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final meals = data['meals'] as List<dynamic>?;
      if (meals == null) return [];
      return meals
          .map((m) => Recipe.fromMealJson(m as Map<String, dynamic>))
          .toList();
    } else {
      throw Exception('Failed to load recipes');
    }
  }

  /// Get recipes by a specific ingredient (e.g. Chicken, Tomato, Egg)
  Future<List<Recipe>> getRecipesByIngredient(String ingredient) async {
    final cleanIngredient = Uri.encodeComponent(ingredient.trim());
    final uri = Uri.parse('$_baseUrl/filter.php?i=$cleanIngredient');
    final response = await http.get(uri);

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final meals = data['meals'] as List<dynamic>?;
      if (meals == null) return [];
      return meals
          .map((m) => Recipe.fromFilterJson(m as Map<String, dynamic>))
          .toList();
    } else {
      throw Exception('Failed to load recipes for $ingredient');
    }
  }

  /// Fetch full details and instructions for a specific meal
  Future<Recipe?> getRecipeDetails(String id) async {
    final uri = Uri.parse('$_baseUrl/lookup.php?i=$id');
    final response = await http.get(uri);

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final meals = data['meals'] as List<dynamic>?;
      if (meals == null || meals.isEmpty) return null;
      return Recipe.fromMealJson(meals.first as Map<String, dynamic>);
    } else {
      throw Exception('Failed to fetch recipe details');
    }
  }

  /// Fetch multiple random recipes for initial discovery
  Future<List<Recipe>> getRandomRecipes({int count = 6}) async {
    final List<Recipe> results = [];
    for (int i = 0; i < count; i++) {
      try {
        final uri = Uri.parse('$_baseUrl/random.php');
        final response = await http.get(uri);
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final meals = data['meals'] as List<dynamic>?;
          if (meals != null && meals.isNotEmpty) {
            results.add(Recipe.fromMealJson(meals.first as Map<String, dynamic>));
          }
        }
      } catch (_) {
        // Continue if single random call fails
      }
    }
    return results;
  }
}
