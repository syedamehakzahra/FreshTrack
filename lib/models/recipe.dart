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
      final ingredient = json['strIngredient$i'];
      final measure = json['strMeasure$i'];
      if (ingredient != null &&
          ingredient is String &&
          ingredient.trim().isNotEmpty) {
        final measureStr =
            (measure != null && measure is String && measure.trim().isNotEmpty)
                ? ' (${measure.trim()})'
                : '';
        ingredientsList.add('${ingredient.trim()}$measureStr');
      }
    }

    return Recipe(
      id: json['idMeal'] ?? '',
      title: json['strMeal'] ?? '',
      thumbnail: json['strMealThumb'] ?? '',
      category: json['strCategory'] ?? '',
      area: json['strArea'] ?? '',
      instructions: json['strInstructions'] ?? '',
      ingredients: ingredientsList,
    );
  }

  factory Recipe.fromFilterJson(Map<String, dynamic> json) {
    return Recipe(
      id: json['idMeal'] ?? '',
      title: json['strMeal'] ?? '',
      thumbnail: json['strMealThumb'] ?? '',
    );
  }
}
