import 'package:flutter/material.dart';
import '../models/recipe.dart';
import '../services/recipe_service.dart';

class RecipeDetailScreen extends StatefulWidget {
  final Recipe recipe;

  const RecipeDetailScreen({super.key, required this.recipe});

  @override
  State<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends State<RecipeDetailScreen> {
  final RecipeService _recipeService = RecipeService();
  Recipe? _detailedRecipe;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    // If the recipe already has full instructions, use it directly
    if (widget.recipe.instructions.isNotEmpty) {
      setState(() {
        _detailedRecipe = widget.recipe;
        _loading = false;
      });
      return;
    }

    try {
      final details = await _recipeService.getRecipeDetails(widget.recipe.id);
      if (mounted) {
        setState(() {
          _detailedRecipe = details ?? widget.recipe;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _detailedRecipe = widget.recipe;
          _loading = false;
          _error = 'Could not load full instructions: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final recipe = _detailedRecipe ?? widget.recipe;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 260,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                recipe.title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(
                      offset: Offset(0, 1),
                      blurRadius: 4,
                      color: Colors.black87,
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              background: recipe.thumbnail.isNotEmpty
                  ? Image.network(
                      recipe.thumbnail,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: colorScheme.surfaceVariant,
                        child: const Icon(Icons.restaurant, size: 60),
                      ),
                    )
                  : Container(
                      color: colorScheme.primaryContainer,
                      child: const Icon(Icons.restaurant, size: 60),
                    ),
            ),
          ),
          SliverToBoxAdapter(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Badges for Category and Origin/Area
                        Wrap(
                          spacing: 8,
                          children: [
                            if (recipe.category.isNotEmpty)
                              Chip(
                                avatar: const Icon(Icons.category, size: 16),
                                label: Text(recipe.category),
                              ),
                            if (recipe.area.isNotEmpty)
                              Chip(
                                avatar: const Icon(Icons.public, size: 16),
                                label: Text(recipe.area),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Ingredients Section
                        if (recipe.ingredients.isNotEmpty) ...[
                          Text(
                            'Ingredients',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Card(
                            elevation: 0,
                            color: colorScheme.surfaceVariant.withOpacity(0.4),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                children: recipe.ingredients
                                    .map(
                                      (ing) => Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 4),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.check_circle,
                                              size: 16,
                                              color: colorScheme.primary,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                ing,
                                                style: theme.textTheme.bodyMedium,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],

                        // Instructions Section
                        if (recipe.instructions.isNotEmpty) ...[
                          Text(
                            'Instructions',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            recipe.instructions,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.6,
                            ),
                          ),
                        ] else if (_error != null) ...[
                          Text(
                            _error!,
                            style: TextStyle(color: colorScheme.error),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
