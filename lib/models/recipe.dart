class Recipe {
  final String id;
  final String title;
  final String thumbnail;
  final String category;
  final String area;
  final String instructions;
  final List<String> ingredients;

  Recipe({
    required this.id,
    required this.title,
    required this.thumbnail,
    this.category = '',
    this.area = '',
    this.instructions = '',
    this.ingredients = const [],
  });

  factory Recipe.fromMealJson(Map<String, dynamic> json) {
    final ingredientsList = <String>[];
    for (int i = 1; i <= 20; i++) {
      final rawIngredient = json['strIngredient$i'];
      final rawMeasure = json['strMeasure$i'];
      final ingredient =
          rawIngredient is String ? rawIngredient.trim() : '';
      if (ingredient.isNotEmpty) {
        final measureStr =
            (rawMeasure is String && rawMeasure.trim().isNotEmpty)
                ? ' (${rawMeasure.trim()})'
                : '';
        ingredientsList.add('$ingredient$measureStr');
      }
    }

    return Recipe(
      id: (json['idMeal'] ?? '').toString(),
      title: (json['strMeal'] ?? '').toString(),
      thumbnail: (json['strMealThumb'] ?? '').toString(),
      category: (json['strCategory'] ?? '').toString(),
      area: (json['strArea'] ?? '').toString(),
      instructions: (json['strInstructions'] ?? '').toString(),
      ingredients: ingredientsList,
    );
  }

  factory Recipe.fromFilterJson(Map<String, dynamic> json) {
    return Recipe(
      id: (json['idMeal'] ?? '').toString(),
      title: (json['strMeal'] ?? '').toString(),
      thumbnail: (json['strMealThumb'] ?? '').toString(),
    );
  }
}
