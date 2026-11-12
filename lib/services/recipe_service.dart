import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/recipe.dart';

class RecipeService {
  static const String _host = 'www.themealdb.com';
  static const String _basePath = '/api/json/v1/1';
  static const Duration defaultTimeout = Duration(seconds: 10);

  final http.Client _client;
  final Duration timeout;

  RecipeService({
    http.Client? client,
    this.timeout = defaultTimeout,
  }) : _client = client ?? http.Client();

  Future<Map<String, dynamic>> _getJsonObject(
    Uri uri,
    String errorContext,
  ) async {
    try {
      final response = await _client.get(uri).timeout(timeout);
      if (response.statusCode != 200) {
        throw Exception('$errorContext (HTTP ${response.statusCode})');
      }
      final decoded = json.decode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected a JSON object response.');
      }
      return decoded;
    } on TimeoutException {
      throw Exception('Request timed out. Please check your internet connection.');
    } on FormatException {
      throw Exception('Received invalid recipe data from server.');
    } on http.ClientException catch (e) {
      throw Exception('Network error: ${e.message}');
    }
  }

  List<Recipe> _parseMeals(
    Map<String, dynamic> data,
    Recipe Function(Map<String, dynamic>) mapper,
  ) {
    final meals = data['meals'];
    if (meals == null) return const [];
    if (meals is! List) {
      throw Exception('Received invalid recipe data from server.');
    }

    final parsed = <Recipe>[];
    for (final entry in meals) {
      if (entry is Map<String, dynamic>) {
        parsed.add(mapper(entry));
      } else if (entry is Map) {
        parsed.add(mapper(Map<String, dynamic>.from(entry)));
      }
    }
    return parsed;
  }

  /// Search recipes by meal name or keyword
  Future<List<Recipe>> searchRecipes(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return getRandomRecipes(count: 6);
    }

    final uri = Uri.https(_host, '$_basePath/search.php', {'s': trimmed});
    final data = await _getJsonObject(uri, 'Failed to load recipes');
    return _parseMeals(data, Recipe.fromMealJson);
  }

  /// Get recipes by a specific ingredient (e.g. Chicken, Tomato, Egg)
  Future<List<Recipe>> getRecipesByIngredient(String ingredient) async {
    final trimmed = ingredient.trim();
    if (trimmed.isEmpty) return const [];

    final uri = Uri.https(_host, '$_basePath/filter.php', {'i': trimmed});
    final data = await _getJsonObject(
      uri,
      'Failed to load recipes for $trimmed',
    );
    return _parseMeals(data, Recipe.fromFilterJson);
  }

  /// Fetch full details and instructions for a specific meal
  Future<Recipe?> getRecipeDetails(String id) async {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.https(_host, '$_basePath/lookup.php', {'i': trimmed});
    final data = await _getJsonObject(uri, 'Failed to fetch recipe details');
    final list = _parseMeals(data, Recipe.fromMealJson);
    return list.isEmpty ? null : list.first;
  }

  Future<Recipe?> _fetchSingleRandomRecipe() async {
    final uri = Uri.https(_host, '$_basePath/random.php');
    final data = await _getJsonObject(uri, 'Failed to load random recipe');
    final list = _parseMeals(data, Recipe.fromMealJson);
    return list.isEmpty ? null : list.first;
  }

  /// Fetch multiple unique random recipes in parallel for initial discovery
  Future<List<Recipe>> getRandomRecipes({int count = 6}) async {
    if (count < 1) return const [];

    Object? firstError;
    final fetched = await Future.wait<Recipe?>(
      List.generate(count, (_) async {
        try {
          return await _fetchSingleRandomRecipe();
        } catch (e) {
          firstError ??= e;
          return null;
        }
      }),
    );

    final seenIds = <String>{};
    final uniqueResults = <Recipe>[];
    for (final recipe in fetched) {
      if (recipe == null || recipe.id.isEmpty) continue;
      if (seenIds.add(recipe.id)) {
        uniqueResults.add(recipe);
      }
    }

    if (uniqueResults.isEmpty && firstError != null) {
      throw firstError!;
    }
    return uniqueResults;
  }
}
