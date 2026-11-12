import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/food_item.dart';
import '../models/shopping_item.dart';
import '../models/waste_log.dart';
import '../services/food_service.dart';
import '../services/shopping_service.dart';
import '../services/stats_service.dart';
import 'add_edit_screen.dart';

class ShoppingItemDraft {
  final String name;
  final String category;
  final String storageLocation;
  final int quantity;

  const ShoppingItemDraft({
    required this.name,
    required this.category,
    required this.storageLocation,
    required this.quantity,
  });
}

class ShoppingScreen extends StatefulWidget {
  final String? userId;
  final Stream<List<ShoppingItem>>? shoppingStream;
  final Stream<List<FoodItem>>? pantryStream;
  final Stream<List<WasteLog>>? logsStream;
  final ShoppingService? shoppingService;
  final VoidCallback? onLogout;

  const ShoppingScreen({
    super.key,
    this.userId,
    this.shoppingStream,
    this.pantryStream,
    this.logsStream,
    this.shoppingService,
    this.onLogout,
  });

  @override
  State<ShoppingScreen> createState() => _ShoppingScreenState();
}

class _ShoppingScreenState extends State<ShoppingScreen> {
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  late ShoppingService _shoppingService;
  late FoodService _foodService;
  late StatsService _statsService;

  late Stream<List<ShoppingItem>> _shoppingStream;
  late Stream<List<FoodItem>> _pantryStream;
  late Stream<List<WasteLog>> _logsStream;

  ScaffoldMessengerState _messenger() =>
      _messengerKey.currentState ?? ScaffoldMessenger.of(context);

  @override
  void initState() {
    super.initState();
    _initServicesAndStreams();
  }

  void _initServicesAndStreams() {
    _shoppingService =
        widget.shoppingService ?? ShoppingService(userId: widget.userId);
    _foodService = FoodService(userId: widget.userId);
    _statsService = StatsService(userId: widget.userId);

    _shoppingStream = widget.shoppingStream ?? _shoppingService.streamItems();
    _pantryStream = widget.pantryStream ?? _foodService.streamItems();
    _logsStream = widget.logsStream ?? _statsService.streamLogs();
  }

  @override
  void didUpdateWidget(covariant ShoppingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _messengerKey.currentState?.clearSnackBars();
    }
    if (oldWidget.userId != widget.userId ||
        oldWidget.shoppingStream != widget.shoppingStream ||
        oldWidget.pantryStream != widget.pantryStream ||
        oldWidget.logsStream != widget.logsStream ||
        oldWidget.shoppingService != widget.shoppingService) {
      _initServicesAndStreams();
    }
  }

  IconData _storageIcon(String location) {
    switch (location) {
      case 'Fridge':
        return Icons.kitchen_outlined;
      case 'Freezer':
        return Icons.ac_unit;
      default:
        return Icons.inventory_2_outlined;
    }
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout?'),
        content: const Text('Are you sure you want to sign out of FreshTrack?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _messengerKey.currentState?.clearSnackBars();
    if (widget.onLogout != null) {
      widget.onLogout!();
    } else {
      await FirebaseAuth.instance.signOut();
    }
  }

  Future<void> _changeQuantity(ShoppingItem item, int nextQuantity) async {
    if (nextQuantity < 1) return;
    final messenger = _messenger();
    final targetUid = widget.userId;
    try {
      await _shoppingService.updateQuantity(item, nextQuantity);
    } catch (e) {
      if (!mounted || widget.userId != targetUid) return;
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not update "${item.name}" quantity: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> _openAddDialog(List<ShoppingItem> currentItems) async {
    final draft = await showDialog<ShoppingItemDraft>(
      context: context,
      builder: (_) => ShoppingItemFormDialog(currentItems: currentItems),
    );
    if (draft == null || !mounted) return;

    final messenger = _messenger();
    try {
      final result = await _shoppingService.addOrMergeItem(
        name: draft.name,
        category: draft.category,
        storageLocation: draft.storageLocation,
        quantity: draft.quantity,
        source: ShoppingItem.sourceManual,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.merged
                ? 'Updated "${result.item.name}" on Shopping List (Qty ${result.item.quantity})'
                : 'Added "${result.item.name}" to Shopping List',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not add item: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> _openEditDialog(
    ShoppingItem item,
    List<ShoppingItem> currentItems,
  ) async {
    final draft = await showDialog<ShoppingItemDraft>(
      context: context,
      builder: (_) => ShoppingItemFormDialog(
        existing: item,
        currentItems: currentItems,
      ),
    );
    if (draft == null || !mounted) return;

    final messenger = _messenger();
    try {
      final result = await _shoppingService.updateItem(
        original: item,
        name: draft.name,
        category: draft.category,
        storageLocation: draft.storageLocation,
        quantity: draft.quantity,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.merged
                ? 'Merged into "${result.item.name}" (Qty ${result.item.quantity})'
                : 'Updated "${result.item.name}"',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not update item: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> _quickAddSuggestion(BuyAgainSuggestion suggestion) async {
    final messenger = _messenger();
    try {
      final result = await _shoppingService.addOrMergeItem(
        name: suggestion.name,
        category: suggestion.category,
        storageLocation: suggestion.storageLocation,
        quantity: 1,
        source: ShoppingItem.sourceBuyAgain,
      );
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.merged
                ? 'Updated "${result.item.name}" on Shopping List (Qty ${result.item.quantity})'
                : 'Added "${result.item.name}" to Shopping List',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not queue item: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> _restockSingleItem(
    ShoppingItem item,
    Set<String> pantryNormalizedNames,
  ) async {
    final messenger = _messenger();
    final result = await Navigator.push<RestockResult?>(
      context,
      MaterialPageRoute(
        builder: (_) => AddEditScreen(
          userId: widget.userId,
          fromShoppingItem: item,
          alreadyInPantryHint:
              pantryNormalizedNames.contains(item.normalizedName),
        ),
      ),
    );
    if (result == null || !mounted) return;

    if (result.restockedCount > 0) {
      final mergedNote = result.mergedPantryCount > 0
          ? ' (merged with matching Pantry item)'
          : '';
      messenger.showSnackBar(
        SnackBar(
          content: Text('Moved "${item.name}" to Pantry$mergedNote'),
          backgroundColor: Colors.green.shade700,
        ),
      );
    }
  }

  Future<void> _openBulkRestockDialog(
    List<ShoppingItem> checkedItems,
    Set<String> pantryNormalizedNames,
  ) async {
    if (checkedItems.isEmpty) return;
    final messenger = _messenger();
    final result = await showDialog<RestockResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BulkRestockDialog(
        items: checkedItems,
        pantryNormalizedNames: pantryNormalizedNames,
        onSubmit: (entries) => _shoppingService.restockItems(entries),
      ),
    );
    if (result == null || !mounted) return;

    if (result.restockedCount > 0) {
      final details = <String>[
        if (result.createdPantryCount > 0)
          '${result.createdPantryCount} added',
        if (result.mergedPantryCount > 0)
          '${result.mergedPantryCount} merged',
      ].join(', ');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Moved ${result.restockedCount} item(s) to Pantry'
            '${details.isNotEmpty ? ' ($details)' : ''}',
          ),
          backgroundColor: Colors.green.shade700,
        ),
      );
    }
  }

  Future<void> _confirmClearChecked(List<ShoppingItem> shoppingItems) async {
    final checkedCount = shoppingItems.where((i) => i.isChecked).length;
    if (checkedCount == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear checked items?'),
        content: Text(
          'Remove $checkedCount checked item(s) from your shopping list without adding them to Pantry?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = _messenger();
    try {
      await _shoppingService.clearChecked(shoppingItems);
      messenger.showSnackBar(
        SnackBar(content: Text('Cleared $checkedCount checked item(s)')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not clear checked items: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return StreamBuilder<List<ShoppingItem>>(
      stream: _shoppingStream,
      builder: (context, shoppingSnap) {
        final shoppingItems = shoppingSnap.data ?? const <ShoppingItem>[];
        final checkedItems =
            shoppingItems.where((item) => item.isChecked).toList();

        return ScaffoldMessenger(
          key: _messengerKey,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Shopping List'),
              actions: [
                if (checkedItems.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear checked items',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () => _confirmClearChecked(shoppingItems),
                  ),
                IconButton(
                  tooltip: 'Logout',
                  icon: const Icon(Icons.logout),
                  onPressed: _confirmLogout,
                ),
              ],
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => _openAddDialog(shoppingItems),
              icon: const Icon(Icons.add),
              label: const Text('Add item'),
            ),
            body: _buildBody(
              context,
              theme,
              colorScheme,
              shoppingSnap,
              shoppingItems,
              checkedItems,
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
    AsyncSnapshot<List<ShoppingItem>> shoppingSnap,
    List<ShoppingItem> shoppingItems,
    List<ShoppingItem> checkedItems,
  ) {
    if (shoppingSnap.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Error: ${shoppingSnap.error}'),
        ),
      );
    }
    if (!shoppingSnap.hasData) {
      return const Center(child: CircularProgressIndicator());
    }

    return StreamBuilder<List<FoodItem>>(
      stream: _pantryStream,
      builder: (context, pantrySnap) {
        final pantryItems = pantrySnap.data ?? const <FoodItem>[];
        final pantryNormalizedNames = <String>{
          for (final p in pantryItems)
            if (ShoppingItem.normalizeName(p.name).isNotEmpty)
              ShoppingItem.normalizeName(p.name),
        };

        return StreamBuilder<List<WasteLog>>(
          stream: _logsStream,
          builder: (context, logsSnap) {
            final logs = logsSnap.data ?? const <WasteLog>[];
            final suggestions = ShoppingService.buildBuyAgainSuggestions(
              logs: logs,
              pantryItems: pantryItems,
              shoppingItems: shoppingItems,
            );

            return Column(
              children: [
                if (suggestions.isNotEmpty)
                  _BuyAgainSection(
                    suggestions: suggestions,
                    onTapSuggestion: _quickAddSuggestion,
                  ),
                if (checkedItems.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.checklist_rtl,
                          color: colorScheme.onPrimaryContainer,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${checkedItems.length} checked',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: () => _openBulkRestockDialog(
                            checkedItems,
                            pantryNormalizedNames,
                          ),
                          icon: const Icon(Icons.kitchen_outlined, size: 18),
                          label: const Text('Move to Pantry'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: shoppingItems.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.shopping_cart_outlined,
                                  size: 64,
                                  color: colorScheme.outline,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Your shopping list is empty',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  suggestions.isNotEmpty
                                      ? 'Tap a Buy Again chip above, or tap "Add item" to add groceries.'
                                      : 'Tap "Add item" or add items from your Pantry to build your next shopping trip.',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 96),
                          itemCount: shoppingItems.length,
                          itemBuilder: (context, index) {
                            final item = shoppingItems[index];
                            final inPantry = pantryNormalizedNames
                                .contains(item.normalizedName);

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Dismissible(
                                key: ValueKey(item.id),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.red.shade600,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'REMOVE',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      Icon(Icons.delete_outline,
                                          color: Colors.white),
                                    ],
                                  ),
                                ),
                                onDismissed: (_) async {
                                  final messenger = _messenger();
                                  final targetUid = widget.userId;
                                  final shoppingService = _shoppingService;
                                  try {
                                    await shoppingService.deleteItem(item.id);
                                    if (!mounted || widget.userId != targetUid) {
                                      return;
                                    }
                                    messenger.clearSnackBars();
                                    messenger.showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Removed "${item.name}" from Shopping List',
                                        ),
                                        action: SnackBarAction(
                                          label: 'Undo',
                                          onPressed: () async {
                                            if (!mounted ||
                                                widget.userId != targetUid) {
                                              return;
                                            }
                                            try {
                                              await shoppingService
                                                  .addOrMergeItem(
                                                name: item.name,
                                                category: item.category,
                                                storageLocation:
                                                    item.storageLocation,
                                                quantity: item.quantity,
                                                source: item.source,
                                              );
                                            } catch (e) {
                                              if (!mounted ||
                                                  widget.userId != targetUid) {
                                                return;
                                              }
                                              messenger.showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    'Could not restore "${item.name}": $e',
                                                  ),
                                                  backgroundColor:
                                                      Colors.red.shade700,
                                                ),
                                              );
                                            }
                                          },
                                        ),
                                      ),
                                    );
                                  } catch (e) {
                                    if (!mounted || widget.userId != targetUid) {
                                      return;
                                    }
                                    messenger.showSnackBar(
                                      SnackBar(
                                        content:
                                            Text('Could not remove item: $e'),
                                        backgroundColor: Colors.red.shade700,
                                      ),
                                    );
                                  }
                                },
                                child: Card(
                                  elevation: 0,
                                  color: item.isChecked
                                      ? colorScheme.surfaceContainerHighest
                                          .withValues(alpha: 0.45)
                                      : colorScheme.surfaceContainerLow,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    side: BorderSide(
                                      color: item.isChecked
                                          ? colorScheme.primary
                                              .withValues(alpha: 0.45)
                                          : colorScheme.outlineVariant,
                                    ),
                                  ),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(14),
                                    onTap: () =>
                                        _openEditDialog(item, shoppingItems),
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          4, 8, 12, 8),
                                      child: Column(
                                        children: [
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Checkbox(
                                                value: item.isChecked,
                                                onChanged: (val) async {
                                                  if (val == null) return;
                                                  try {
                                                    await _shoppingService
                                                        .toggleChecked(
                                                            item, val);
                                                  } catch (e) {
                                                    if (!mounted) {
                                                      return;
                                                    }
                                                    _messenger().showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          'Could not update item: $e',
                                                        ),
                                                        backgroundColor:
                                                            Colors.red.shade700,
                                                      ),
                                                    );
                                                  }
                                                },
                                              ),
                                              Expanded(
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          top: 8),
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        item.name,
                                                        style: theme.textTheme
                                                            .titleMedium
                                                            ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          decoration: item
                                                                  .isChecked
                                                              ? TextDecoration
                                                                  .lineThrough
                                                              : null,
                                                          color: item.isChecked
                                                              ? colorScheme
                                                                  .outline
                                                              : null,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 4),
                                                      Wrap(
                                                        spacing: 6,
                                                        runSpacing: 4,
                                                        crossAxisAlignment:
                                                            WrapCrossAlignment
                                                                .center,
                                                        children: [
                                                          Text(
                                                            item.category,
                                                            style: theme
                                                                .textTheme
                                                                .bodySmall
                                                                ?.copyWith(
                                                              color: colorScheme
                                                                  .onSurfaceVariant,
                                                            ),
                                                          ),
                                                          Icon(
                                                            _storageIcon(item
                                                                .storageLocation),
                                                            size: 13,
                                                            color: colorScheme
                                                                .onSurfaceVariant,
                                                          ),
                                                          Text(
                                                            item.storageLocation,
                                                            style: theme
                                                                .textTheme
                                                                .bodySmall
                                                                ?.copyWith(
                                                              color: colorScheme
                                                                  .onSurfaceVariant,
                                                            ),
                                                          ),
                                                          if (inPantry)
                                                            Container(
                                                              padding:
                                                                  const EdgeInsets
                                                                      .symmetric(
                                                                horizontal: 6,
                                                                vertical: 1,
                                                              ),
                                                              decoration:
                                                                  BoxDecoration(
                                                                color: Colors
                                                                    .teal
                                                                    .withValues(
                                                                        alpha:
                                                                            0.12),
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            8),
                                                              ),
                                                              child: Text(
                                                                'In pantry',
                                                                style: TextStyle(
                                                                  fontSize: 10,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                  color: Colors
                                                                      .teal
                                                                      .shade800,
                                                                ),
                                                              ),
                                                            ),
                                                        ],
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Row(
                                            children: [
                                              const SizedBox(width: 8),
                                              IconButton(
                                                tooltip: 'Decrease quantity',
                                                visualDensity:
                                                    VisualDensity.compact,
                                                icon: const Icon(
                                                  Icons.remove_circle_outline,
                                                  size: 20,
                                                ),
                                                onPressed: item.quantity > 1
                                                    ? () => _changeQuantity(
                                                          item,
                                                          item.quantity - 1,
                                                        )
                                                    : null,
                                              ),
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 4),
                                                child: Text(
                                                  'Qty ${item.quantity}',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: 'Increase quantity',
                                                visualDensity:
                                                    VisualDensity.compact,
                                                icon: const Icon(
                                                  Icons.add_circle_outline,
                                                  size: 20,
                                                ),
                                                onPressed: () =>
                                                    _changeQuantity(
                                                  item,
                                                  item.quantity + 1,
                                                ),
                                              ),
                                              const Spacer(),
                                              FilledButton.tonalIcon(
                                                onPressed: () =>
                                                    _restockSingleItem(
                                                  item,
                                                  pantryNormalizedNames,
                                                ),
                                                icon: const Icon(
                                                  Icons.kitchen_outlined,
                                                  size: 16,
                                                ),
                                                label: const Text('Restock'),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _BuyAgainSection extends StatelessWidget {
  final List<BuyAgainSuggestion> suggestions;
  final void Function(BuyAgainSuggestion) onTapSuggestion;

  const _BuyAgainSection({
    required this.suggestions,
    required this.onTapSuggestion,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history, size: 17, color: colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                'Buy Again',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'From recent pantry history',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.outline,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: suggestions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final suggestion = suggestions[index];
                return ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text(suggestion.name),
                  tooltip:
                      'Last ${suggestion.lastAction} • Tap to add to Shopping List',
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onPressed: () => onTapSuggestion(suggestion),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ShoppingItemFormDialog extends StatefulWidget {
  final ShoppingItem? existing;
  final List<ShoppingItem> currentItems;

  const ShoppingItemFormDialog({
    super.key,
    this.existing,
    this.currentItems = const [],
  });

  @override
  State<ShoppingItemFormDialog> createState() => _ShoppingItemFormDialogState();
}

class _ShoppingItemFormDialogState extends State<ShoppingItemFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _quantityController;
  late String _category;
  late String _storageLocation;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _quantityController = TextEditingController(
      text: (existing?.quantity ?? 1).toString(),
    );
    _category = FoodItem.normalizeCategory(existing?.category);
    _storageLocation = FoodItem.normalizeStorageLocation(
      existing?.storageLocation,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    super.dispose();
  }

  ShoppingItem? _matchingExistingByName() {
    final normalized = ShoppingItem.normalizeName(_nameController.text);
    if (normalized.isEmpty) return null;
    for (final item in widget.currentItems) {
      if (widget.existing != null && item.id == widget.existing!.id) continue;
      if (item.normalizedName == normalized) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final duplicateMatch = _matchingExistingByName();

    return AlertDialog(
      title: Text(_isEditing ? 'Edit Shopping Item' : 'Add to Shopping List'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _nameController,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(FoodItem.maxNameLength),
                ],
                decoration: const InputDecoration(
                  labelText: 'Food name',
                  prefixIcon: Icon(Icons.fastfood_outlined),
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
                validator: (value) {
                  final cleaned = ShoppingItem.cleanDisplayName(value ?? '');
                  if (cleaned.isEmpty) {
                    return 'Please enter the food name';
                  }
                  if (cleaned.length > FoodItem.maxNameLength) {
                    return 'Food name must be ${FoodItem.maxNameLength} characters or fewer';
                  }
                  return null;
                },
              ),
              if (duplicateMatch != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.merge_type,
                          size: 16, color: Colors.blue.shade700),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Already on list (Qty ${duplicateMatch.quantity}) — saving will combine quantities.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.blue.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  prefixIcon: Icon(Icons.category_outlined),
                  border: OutlineInputBorder(),
                ),
                items: FoodItem.categories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => _category = value);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _storageLocation,
                decoration: const InputDecoration(
                  labelText: 'Default storage location',
                  prefixIcon: Icon(Icons.inventory_2_outlined),
                  border: OutlineInputBorder(),
                ),
                items: FoodItem.storageLocations
                    .map((loc) => DropdownMenuItem(value: loc, child: Text(loc)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => _storageLocation = value);
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _quantityController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Quantity',
                  prefixIcon: Icon(Icons.numbers),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final n = int.tryParse(value?.trim() ?? '');
                  if (n == null || n < 1) {
                    return 'Enter a quantity of 1 or more';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(
              context,
              ShoppingItemDraft(
                name: _nameController.text.trim(),
                category: _category,
                storageLocation: _storageLocation,
                quantity: int.parse(_quantityController.text.trim()),
              ),
            );
          },
          child: Text(_isEditing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

class _RestockRowState {
  final ShoppingItem shoppingItem;
  final TextEditingController qtyController;
  final TextEditingController priceController;
  String storageLocation;
  DateTime? expiryDate;

  _RestockRowState(this.shoppingItem)
      : qtyController =
            TextEditingController(text: shoppingItem.quantity.toString()),
        priceController = TextEditingController(),
        storageLocation = FoodItem.normalizeStorageLocation(
          shoppingItem.storageLocation,
        ),
        expiryDate = null;

  void dispose() {
    qtyController.dispose();
    priceController.dispose();
  }
}

class BulkRestockDialog extends StatefulWidget {
  final List<ShoppingItem> items;
  final Set<String> pantryNormalizedNames;
  final Future<RestockResult> Function(List<RestockEntry> entries) onSubmit;
  final DateTime? referenceNow;

  const BulkRestockDialog({
    super.key,
    required this.items,
    this.pantryNormalizedNames = const {},
    required this.onSubmit,
    this.referenceNow,
  });

  @override
  State<BulkRestockDialog> createState() => _BulkRestockDialogState();
}

class _BulkRestockDialogState extends State<BulkRestockDialog> {
  final _formKey = GlobalKey<FormState>();
  late final List<_RestockRowState> _rows;
  bool _validationTriggered = false;
  bool _saving = false;
  String? _submitError;
  RestockResult? _partialResult;

  @override
  void initState() {
    super.initState();
    _rows = widget.items.map(_RestockRowState.new).toList();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  DateTime get _today {
    final now = widget.referenceNow ?? DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  String _formatDate(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }

  Future<void> _pickRowDate(_RestockRowState row) async {
    final today = _today;
    final initial =
        (row.expiryDate != null && !row.expiryDate!.isBefore(today))
            ? row.expiryDate!
            : today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: today,
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        row.expiryDate = DateTime(picked.year, picked.month, picked.day);
        _submitError = null;
      });
    }
  }

  Future<void> _applyDateToUnsetRows() async {
    final today = _today;
    final picked = await showDatePicker(
      context: context,
      initialDate: today,
      firstDate: today,
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    final normalized = DateTime(picked.year, picked.month, picked.day);
    setState(() {
      for (final row in _rows) {
        row.expiryDate ??= normalized;
      }
      _submitError = null;
    });
  }

  Future<void> _submit() async {
    if (_rows.isEmpty) {
      Navigator.pop(context, _partialResult);
      return;
    }

    setState(() {
      _validationTriggered = true;
      _submitError = null;
    });

    final formValid = _formKey.currentState!.validate();
    final today = _today;
    final hasInvalidDates = _rows.any(
      (r) => r.expiryDate == null || r.expiryDate!.isBefore(today),
    );

    if (!formValid || hasInvalidDates) {
      setState(() {
        if (hasInvalidDates) {
          _submitError =
              'Please choose a valid expiry date for every checked item.';
        }
      });
      return;
    }

    final entries = <RestockEntry>[];
    for (final row in _rows) {
      final qty = int.parse(row.qtyController.text.trim());
      final rawPriceText = row.priceController.text.trim();
      final price = rawPriceText.isEmpty ? null : double.tryParse(rawPriceText);
      entries.add(
        RestockEntry(
          shoppingItem: row.shoppingItem,
          quantity: qty,
          storageLocation: row.storageLocation,
          expiryDate: row.expiryDate!,
          totalPrice: price,
        ),
      );
    }

    setState(() => _saving = true);
    try {
      final result = await widget.onSubmit(entries);
      if (!mounted) return;
      final combined =
          _partialResult == null ? result : _partialResult!.combineWith(result);
      Navigator.pop(context, combined);
    } on PartialRestockException catch (e) {
      if (!mounted) return;
      final completedSet = e.completedShoppingIds.toSet();
      final nextPartial = _partialResult == null
          ? e.completedResult
          : _partialResult!.combineWith(e.completedResult);

      setState(() {
        _saving = false;
        _partialResult = nextPartial;
        for (var i = _rows.length - 1; i >= 0; i--) {
          if (completedSet.contains(_rows[i].shoppingItem.id)) {
            _rows[i].dispose();
            _rows.removeAt(i);
          }
        }
        _submitError = nextPartial.restockedCount > 0
            ? 'Moved ${nextPartial.restockedCount} item(s) to Pantry, but '
                '${_rows.length} remaining item(s) failed: ${e.cause}. '
                'Tap Retry Remaining to continue with only the remaining items.'
            : '${completedSet.length} item(s) were already removed from your list. '
                '${_rows.length} remaining item(s) failed: ${e.cause}';
      });

      if (_rows.isEmpty && mounted) {
        Navigator.pop(context, _partialResult);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _submitError = _partialResult != null && _partialResult!.restockedCount > 0
            ? 'Already moved ${_partialResult!.restockedCount} item(s). '
                'Remaining ${_rows.length} item(s) failed: $e'
            : 'Could not restock items: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasUnsetDates = _rows.any((r) => r.expiryDate == null);
    final today = _today;
    final partialMoved = _partialResult?.restockedCount ?? 0;

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text('Move ${_rows.length} Item(s) to Pantry'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (partialMoved > 0) ...[
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.green.shade300),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline,
                            size: 18, color: Colors.green.shade700),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$partialMoved item(s) already moved to Pantry and removed from this batch.',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.green.shade900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                Text(
                  'Choose an expiry date for each item. Optional total price (Rs.) tracks food value.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (hasUnsetDates && _rows.length > 1) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _saving ? null : _applyDateToUnsetRows,
                      icon: const Icon(Icons.date_range, size: 18),
                      label: const Text('Set date for all unset items'),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                ..._rows.map((row) {
                  final missingOrPastDate = _validationTriggered &&
                      (row.expiryDate == null ||
                          row.expiryDate!.isBefore(today));
                  final inPantry = widget.pantryNormalizedNames
                      .contains(row.shoppingItem.normalizedName);

                  return Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: missingOrPastDate
                            ? Colors.red.shade600
                            : Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  row.shoppingItem.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              Text(
                                row.shoppingItem.category,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                          if (inPantry) ...[
                            const SizedBox(height: 2),
                            Text(
                              'In Pantry — exact matching details will merge.',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.teal.shade700,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  controller: row.qtyController,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  decoration: const InputDecoration(
                                    labelText: 'Qty',
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(),
                                  ),
                                  validator: (value) {
                                    final n = int.tryParse(value?.trim() ?? '');
                                    if (n == null || n < 1) {
                                      return 'Min 1';
                                    }
                                    return null;
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 3,
                                child: DropdownButtonFormField<String>(
                                  initialValue: row.storageLocation,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Storage',
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(),
                                  ),
                                  items: FoodItem.storageLocations
                                      .map(
                                        (loc) => DropdownMenuItem(
                                          value: loc,
                                          child: Text(loc),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: _saving
                                      ? null
                                      : (val) {
                                          if (val != null) {
                                            setState(
                                                () => row.storageLocation = val);
                                          }
                                        },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed:
                                  _saving ? null : () => _pickRowDate(row),
                              style: missingOrPastDate
                                  ? OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red.shade700,
                                      side: BorderSide(
                                          color: Colors.red.shade700),
                                    )
                                  : null,
                              icon: const Icon(Icons.calendar_today, size: 16),
                              label: Text(
                                row.expiryDate == null
                                    ? 'Choose expiry date *'
                                    : 'Expires: ${_formatDate(row.expiryDate!)}',
                              ),
                            ),
                          ),
                          if (missingOrPastDate) ...[
                            const SizedBox(height: 4),
                            Text(
                              row.expiryDate == null
                                  ? 'Expiry date is required'
                                  : 'Expiry date cannot be in the past',
                              style: TextStyle(
                                color: Colors.red.shade700,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: row.priceController,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'^\d*\.?\d{0,2}')),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Total price (Rs., optional)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) {
                              final text = value?.trim() ?? '';
                              if (text.isEmpty) return null;
                              final parsed = double.tryParse(text);
                              if (parsed == null || parsed <= 0) {
                                return 'Enter > 0 or leave blank';
                              }
                              return null;
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                if (_submitError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _submitError!,
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, _partialResult),
          child: Text(partialMoved > 0 ? 'Done' : 'Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _partialResult != null
                      ? 'Retry Remaining (${_rows.length})'
                      : 'Move to Pantry',
                ),
        ),
      ],
    );
  }
}
