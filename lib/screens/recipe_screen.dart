import 'package:flutter/material.dart';
import '../models/food_item.dart';
import '../models/recipe.dart';
import '../services/food_service.dart';
import '../services/recipe_service.dart';
import 'recipe_detail_screen.dart';

class RecipeScreen extends StatefulWidget {
  final String? userId;
  final String? initialIngredient;
  final Stream<List<FoodItem>>? itemsStream;
  final RecipeService? recipeService;

  const RecipeScreen({
    super.key,
    this.userId,
    this.initialIngredient,
    this.itemsStream,
    this.recipeService,
  });

  @override
  State<RecipeScreen> createState() => _RecipeScreenState();
}

class _RecipeScreenState extends State<RecipeScreen> {
  late RecipeService _recipeService;
  late FoodService _foodService;
  late Stream<List<FoodItem>> _itemsStream;
  final TextEditingController _searchController = TextEditingController();

  List<Recipe> _recipes = [];
  bool _loading = false;
  String? _error;
  String? _selectedIngredient;

  @override
  void initState() {
    super.initState();
    _recipeService = widget.recipeService ?? RecipeService();
    _foodService = FoodService(userId: widget.userId);
    _itemsStream = widget.itemsStream ?? _foodService.streamItems();
    final initial = widget.initialIngredient?.trim();
    if (initial != null && initial.isNotEmpty) {
      _filterByIngredient(initial, isInitial: true);
    } else {
      _loadInitialRecipes(isInitial: true);
    }
  }

  @override
  void didUpdateWidget(covariant RecipeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recipeService != widget.recipeService) {
      _recipeService = widget.recipeService ?? RecipeService();
    }
    if (oldWidget.userId != widget.userId ||
        oldWidget.itemsStream != widget.itemsStream) {
      _foodService = FoodService(userId: widget.userId);
      _itemsStream = widget.itemsStream ?? _foodService.streamItems();
    }
    final nextIngredient = widget.initialIngredient?.trim();
    if (oldWidget.initialIngredient != widget.initialIngredient &&
        nextIngredient != null &&
        nextIngredient.isNotEmpty) {
      _filterByIngredient(nextIngredient, isInitial: true);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialRecipes({bool isInitial = false}) async {
    if (isInitial) {
      _loading = true;
      _error = null;
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final results = await _recipeService.getRandomRecipes(count: 6);
      if (mounted) {
        setState(() {
          _recipes = results;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not load recipes. Check internet connection.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _search(String query) async {
    final text = query.trim();
    if (text.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
      _selectedIngredient = null;
    });

    try {
      final results = await _recipeService.searchRecipes(text);
      if (mounted) {
        setState(() {
          _recipes = results;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Search failed: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _filterByIngredient(
    String ingredient, {
    bool isInitial = false,
  }) async {
    if (isInitial) {
      _loading = true;
      _error = null;
      _selectedIngredient = ingredient;
      _searchController.text = ingredient;
    } else {
      setState(() {
        _loading = true;
        _error = null;
        _selectedIngredient = ingredient;
        _searchController.text = ingredient;
      });
    }

    try {
      final results = await _recipeService.getRecipesByIngredient(ingredient);
      if (mounted) {
        setState(() {
          _recipes = results;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not find recipes for "$ingredient".';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover Recipes'),
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search meals or ingredients...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _selectedIngredient = null);
                          _loadInitialRecipes();
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: _search,
            ),
          ),

          // Pantry Quick Chips (Uses ingredients from Firestore)
          StreamBuilder<List<FoodItem>>(
            stream: _itemsStream,
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return const SizedBox.shrink();
              }
              final seenIngredients = <String>{};
              final ingredientNames = <String>[];
              for (final item in snapshot.data!) {
                if (item.alertLevel == ExpiryAlertLevel.expired) continue;
                final cleaned = FoodItem.cleanDisplayName(item.name);
                final normalized = FoodItem.normalizeName(cleaned);
                if (normalized.isEmpty || !seenIngredients.add(normalized)) {
                  continue;
                }
                ingredientNames.add(cleaned);
              }
              if (ingredientNames.isEmpty) return const SizedBox.shrink();

              return SizedBox(
                height: 48,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: ingredientNames.length,
                  itemBuilder: (context, index) {
                    final ingredient = ingredientNames[index];
                    final isSelected = _selectedIngredient != null &&
                        FoodItem.normalizeName(_selectedIngredient!) ==
                            FoodItem.normalizeName(ingredient);
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        avatar: const Icon(Icons.restaurant_menu, size: 16),
                        label: Text(ingredient),
                        selected: isSelected,
                        onSelected: (_) => _filterByIngredient(ingredient),
                      ),
                    );
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 8),

          // Recipe Results Grid / List
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.error_outline,
                                  size: 48, color: colorScheme.error),
                              const SizedBox(height: 8),
                              Text(_error!, textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                              FilledButton.tonal(
                                onPressed: _loadInitialRecipes,
                                child: const Text('Try Again'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _recipes.isEmpty
                        ? const Center(
                            child: Text(
                              'No recipes found.\nTry searching another ingredient!',
                              textAlign: TextAlign.center,
                            ),
                          )
                        : GridView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                              childAspectRatio: 0.82,
                            ),
                            itemCount: _recipes.length,
                            itemBuilder: (context, index) {
                              final recipe = _recipes[index];
                              return InkWell(
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        RecipeDetailScreen(recipe: recipe),
                                  ),
                                ),
                                borderRadius: BorderRadius.circular(16),
                                child: Card(
                                  elevation: 2,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: recipe.thumbnail.isNotEmpty
                                            ? Image.network(
                                                recipe.thumbnail,
                                                width: double.infinity,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) =>
                                                    Container(
                                                  color: colorScheme
                                                      .surfaceVariant,
                                                  child: const Center(
                                                    child: Icon(
                                                        Icons.restaurant,
                                                        size: 40),
                                                  ),
                                                ),
                                              )
                                            : Container(
                                                color: colorScheme
                                                    .surfaceVariant,
                                                child: const Center(
                                                  child: Icon(
                                                      Icons.restaurant,
                                                      size: 40),
                                                ),
                                              ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.all(10),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              recipe.title,
                                              style: theme
                                                  .textTheme.bodyMedium
                                                  ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (recipe.category.isNotEmpty) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                recipe.category,
                                                style: theme
                                                    .textTheme.bodySmall
                                                    ?.copyWith(
                                                  color: colorScheme.outline,
                                                ),
                                                maxLines: 1,
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}
