import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/food_item.dart';
import '../models/shopping_item.dart';
import '../services/food_service.dart';
import '../services/shopping_service.dart';
import '../utils/price_formatter.dart';
import 'add_edit_screen.dart';
import 'recipe_screen.dart';

class HomeScreen extends StatefulWidget {
  final String? userId;
  final Stream<List<FoodItem>>? itemsStream;
  final VoidCallback? onLogout;
  final DateTime Function()? nowProvider;

  const HomeScreen({
    super.key,
    this.userId,
    this.itemsStream,
    this.onLogout,
    this.nowProvider,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  late FoodService _service;
  late ShoppingService _shoppingService;
  late Stream<List<FoodItem>> _itemsStream;
  late String _currentDayKey;

  ExpiryAlertLevel? _selectedLevel; // null = 'All'
  String _selectedLocation = 'All'; // 'All', 'Fridge', 'Freezer', 'Pantry'
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  DateTime _now() => widget.nowProvider?.call() ?? DateTime.now();

  ScaffoldMessengerState _messenger() =>
      _messengerKey.currentState ?? ScaffoldMessenger.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentDayKey = FoodItem.expiryDayKey(_now());
    _service = FoodService(userId: widget.userId);
    _shoppingService = ShoppingService(userId: widget.userId);
    _itemsStream = widget.itemsStream ?? _service.streamItems();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      final nextDayKey = FoodItem.expiryDayKey(_now());
      if (nextDayKey != _currentDayKey) {
        setState(() => _currentDayKey = nextDayKey);
      }
    }
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.itemsStream != widget.itemsStream) {
      _messengerKey.currentState?.clearSnackBars();
      _service = FoodService(userId: widget.userId);
      _shoppingService = ShoppingService(userId: widget.userId);
      _itemsStream = widget.itemsStream ?? _service.streamItems();
      _selectedLevel = null;
      _selectedLocation = 'All';
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  Color _alertColor(ExpiryAlertLevel level) {
    switch (level) {
      case ExpiryAlertLevel.normal:
        return Colors.green.shade700;
      case ExpiryAlertLevel.expiringSoon:
        return Colors.amber.shade800;
      case ExpiryAlertLevel.urgent:
        return Colors.deepOrange.shade700;
      case ExpiryAlertLevel.expiresToday:
        return Colors.red.shade700;
      case ExpiryAlertLevel.expired:
        return Colors.red.shade900;
    }
  }

  IconData _alertIcon(ExpiryAlertLevel level) {
    switch (level) {
      case ExpiryAlertLevel.normal:
        return Icons.check_circle_outline;
      case ExpiryAlertLevel.expiringSoon:
        return Icons.schedule_outlined;
      case ExpiryAlertLevel.urgent:
        return Icons.warning_amber_rounded;
      case ExpiryAlertLevel.expiresToday:
        return Icons.notifications_active_outlined;
      case ExpiryAlertLevel.expired:
        return Icons.error_outline;
    }
  }

  Color _bannerColor(ExpirySummary summary) {
    if (summary.expiredCount > 0 || summary.expiresTodayCount > 0) {
      return Colors.red.shade700;
    }
    if (summary.urgentCount > 0) {
      return Colors.deepOrange.shade700;
    }
    return Colors.amber.shade800;
  }

  IconData _bannerIcon(ExpirySummary summary) {
    if (summary.expiredCount > 0) {
      return Icons.error_outline;
    }
    if (summary.expiresTodayCount > 0) {
      return Icons.notifications_active_outlined;
    }
    if (summary.urgentCount > 0) {
      return Icons.warning_amber_rounded;
    }
    return Icons.schedule_outlined;
  }

  IconData _locationIcon(String location) {
    switch (location) {
      case 'Fridge':
        return Icons.kitchen_outlined;
      case 'Freezer':
        return Icons.ac_unit;
      default:
        return Icons.inventory_2_outlined;
    }
  }

  Color _locationColor(String location) {
    switch (location) {
      case 'Fridge':
        return Colors.blue.shade700;
      case 'Freezer':
        return Colors.cyan.shade800;
      default:
        return Colors.brown.shade600;
    }
  }

  String _emptyFilterMessage() {
    if (_searchQuery.isNotEmpty) {
      return 'No food items matching "$_searchQuery".';
    }
    if (_selectedLevel != null && _selectedLocation != 'All') {
      return 'No ${FoodItem.statusLabelForLevel(_selectedLevel!)} items in $_selectedLocation.';
    }
    if (_selectedLocation != 'All') {
      return 'No items in $_selectedLocation.';
    }
    if (_selectedLevel != null) {
      return 'No ${FoodItem.statusLabelForLevel(_selectedLevel!)} items found.';
    }
    return 'No food items found.';
  }

  Future<int?> _promptQuantityIfNeeded(FoodItem item, String action) async {
    if (item.quantity <= 1) return 1;
    if (!mounted) return null;
    return showDialog<int>(
      context: context,
      builder: (_) => QuantityActionDialog(item: item, action: action),
    );
  }

  Future<bool> _processItemAction(
    ScaffoldMessengerState messenger,
    FoodItem item, {
    required String action,
    required int quantity,
  }) async {
    final isConsumed = action == 'consumed';
    try {
      final result = await _service.processItemAction(
        item,
        action: action,
        quantity: quantity,
      );
      final qtyLabel = result.processedQuantity > 1
          ? '${result.processedQuantity} × "${item.name}"'
          : '"${item.name}"';
      final remainingSuffix = result.deleted
          ? ''
          : ' (${result.remainingQuantity} left)';
      final targetUid = widget.userId;
      final shoppingService = _shoppingService;

      messenger.showSnackBar(
        SnackBar(
          duration: Duration(seconds: result.deleted ? 5 : 4),
          content: Text(
            isConsumed
                ? '🎉 Consumed $qtyLabel$remainingSuffix'
                : '🗑️ Discarded $qtyLabel$remainingSuffix',
          ),
          backgroundColor:
              isConsumed ? Colors.green.shade700 : Colors.red.shade700,
          action: result.deleted
              ? SnackBarAction(
                  label: 'Buy again',
                  textColor: Colors.white,
                  onPressed: () async {
                    if (!mounted || widget.userId != targetUid) return;
                    try {
                      final added = await shoppingService.addOrMergeItem(
                        name: item.name,
                        category: item.category,
                        storageLocation: item.storageLocation,
                        quantity: 1,
                        source: ShoppingItem.sourceBuyAgain,
                      );
                      messenger.hideCurrentSnackBar();
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            added.merged
                                ? 'Updated "${added.item.name}" on Shopping List (Qty ${added.item.quantity})'
                                : 'Added "${added.item.name}" to Shopping List',
                          ),
                        ),
                      );
                    } catch (e) {
                      messenger.hideCurrentSnackBar();
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text('Could not add to Shopping List: $e'),
                          backgroundColor: Colors.red.shade700,
                        ),
                      );
                    }
                  },
                )
              : null,
        ),
      );
      return result.deleted;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            isConsumed
                ? 'Could not mark as consumed: $e'
                : 'Could not mark as discarded: $e',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return false;
    }
  }

  void _showItemActionSheet(BuildContext context, FoodItem item) {
    final estimatedRemaining = item.remainingEstimatedValue;
    final referenceNow = _now();
    final level = item.alertLevelAt(referenceNow);
    final statusLabel = item.statusAt(referenceNow);
    final daysText = item.daysLeftTextAt(referenceNow);
    final statusColor = _alertColor(level);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: statusColor.withValues(alpha: 0.15),
                      child: Icon(
                        _alertIcon(level),
                        color: statusColor,
                      ),
                    ),
                    title: Text(item.name,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      '${item.category} • ${item.storageLocation} • Qty: ${item.quantity}'
                      '${estimatedRemaining != null ? ' • ${formatPkr(estimatedRemaining)}' : ''}'
                      ' • $statusLabel'
                      '${level == ExpiryAlertLevel.expiresToday ? '' : ' ($daysText)'}',
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    leading:
                        const Icon(Icons.check_circle_outline, color: Colors.green),
                    title: const Text('Mark as Consumed / Eaten'),
                    subtitle: const Text('Logs to stats as saved food'),
                    onTap: () async {
                      final messenger = _messenger();
                      Navigator.pop(ctx);
                      final qty = await _promptQuantityIfNeeded(item, 'consumed');
                      if (qty == null) return;
                      await _processItemAction(
                        messenger,
                        item,
                        action: 'consumed',
                        quantity: qty,
                      );
                    },
                  ),
                  ListTile(
                    leading:
                        const Icon(Icons.delete_outline, color: Colors.redAccent),
                    title: const Text('Mark as Wasted / Discarded'),
                    subtitle: const Text('Logs to food waste statistics'),
                    onTap: () async {
                      final messenger = _messenger();
                      Navigator.pop(ctx);
                      final qty = await _promptQuantityIfNeeded(item, 'wasted');
                      if (qty == null) return;
                      await _processItemAction(
                        messenger,
                        item,
                        action: 'wasted',
                        quantity: qty,
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.menu_book, color: Colors.teal),
                    title: const Text('Find Recipes With This Ingredient'),
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RecipeScreen(
                            userId: widget.userId,
                            initialIngredient: item.name,
                          ),
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(
                      Icons.add_shopping_cart_outlined,
                      color: Colors.indigo,
                    ),
                    title: const Text('Add to Shopping List'),
                    subtitle: const Text('Queue item to buy later'),
                    onTap: () async {
                      final messenger = _messenger();
                      final shoppingService = _shoppingService;
                      Navigator.pop(ctx);
                      try {
                        final added = await shoppingService.addOrMergeItem(
                          name: item.name,
                          category: item.category,
                          storageLocation: item.storageLocation,
                          quantity: 1,
                          source: ShoppingItem.sourcePantry,
                        );
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              added.merged
                                  ? 'Updated "${added.item.name}" on Shopping List (Qty ${added.item.quantity})'
                                  : 'Added "${added.item.name}" to Shopping List',
                            ),
                          ),
                        );
                      } catch (e) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text('Could not add to Shopping List: $e'),
                            backgroundColor: Colors.red.shade700,
                          ),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('Edit Item Details'),
                    onTap: () async {
                      final messenger = _messenger();
                      Navigator.pop(ctx);
                      final updateResult =
                          await Navigator.push<FoodUpdateResult?>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AddEditScreen(
                            item: item,
                            userId: widget.userId,
                          ),
                        ),
                      );
                      if (updateResult?.merged == true && mounted) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              'Merged "${updateResult!.item.name}" with matching batch (Qty ${updateResult.item.quantity})',
                            ),
                            backgroundColor: Colors.green.shade700,
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
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

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My Pantry'),
          actions: [
            IconButton(
              tooltip: 'Logout',
              icon: const Icon(Icons.logout),
              onPressed: _confirmLogout,
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddEditScreen(userId: widget.userId),
          ),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Add item'),
      ),
      body: StreamBuilder<List<FoodItem>>(
        stream: _itemsStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Error: ${snapshot.error}'),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final allItems = snapshot.data!;
          if (allItems.isEmpty) {
            return const Center(
              child: Text(
                'No food items yet.\nTap "Add item" to start.',
                textAlign: TextAlign.center,
              ),
            );
          }

          final referenceNow = _now();
          final expirySummary = ExpirySummary.fromItems(
            allItems,
            referenceNow: referenceNow,
          );
          final bannerMessage = expirySummary.alertBannerMessage;
          final locationCounts = <String, int>{
            for (final loc in FoodItem.storageLocations)
              loc: allItems.where((i) => i.storageLocation == loc).length,
          };

          // Filter by selected status level, storage location, and search
          final normalizedQuery = _searchQuery.toLowerCase();
          final filteredItems = allItems.where((item) {
            final matchesFilter = _selectedLevel == null ||
                item.alertLevelAt(referenceNow) == _selectedLevel;
            final matchesLocation = _selectedLocation == 'All' ||
                item.storageLocation == _selectedLocation;
            final matchesSearch = normalizedQuery.isEmpty ||
                item.name.toLowerCase().contains(normalizedQuery) ||
                item.category.toLowerCase().contains(normalizedQuery) ||
                item.storageLocation.toLowerCase().contains(normalizedQuery);
            return matchesFilter && matchesLocation && matchesSearch;
          }).toList();

          return Column(
            children: [
              // Expiry Reminder Banner (Displays all active alert counts together)
              if (bannerMessage != null)
                Builder(
                  builder: (context) {
                    final bannerColor = _bannerColor(expirySummary);
                    return Container(
                      margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: bannerColor.withValues(alpha: 0.11),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: bannerColor.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _bannerIcon(expirySummary),
                            color: bannerColor,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              bannerMessage,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: bannerColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),

              // Non-overlapping Summary Grid (Tap a box to filter!)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                child: Column(
                  children: [
                    Row(
                      children: [
                        _SummaryBox(
                          label: 'All',
                          count: allItems.length,
                          color: Colors.blueGrey.shade700,
                          isSelected: _selectedLevel == null,
                          onTap: () => setState(() => _selectedLevel = null),
                        ),
                        const SizedBox(width: 6),
                        _SummaryBox(
                          label: 'Normal',
                          count: expirySummary.normalCount,
                          color: _alertColor(ExpiryAlertLevel.normal),
                          isSelected: _selectedLevel == ExpiryAlertLevel.normal,
                          onTap: () => setState(
                            () => _selectedLevel = ExpiryAlertLevel.normal,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _SummaryBox(
                          label: 'Expiring Soon',
                          count: expirySummary.expiringSoonCount,
                          color: _alertColor(ExpiryAlertLevel.expiringSoon),
                          isSelected:
                              _selectedLevel == ExpiryAlertLevel.expiringSoon,
                          onTap: () => setState(
                            () =>
                                _selectedLevel = ExpiryAlertLevel.expiringSoon,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _SummaryBox(
                          label: 'Urgent',
                          count: expirySummary.urgentCount,
                          color: _alertColor(ExpiryAlertLevel.urgent),
                          isSelected: _selectedLevel == ExpiryAlertLevel.urgent,
                          onTap: () => setState(
                            () => _selectedLevel = ExpiryAlertLevel.urgent,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _SummaryBox(
                          label: 'Expires Today',
                          count: expirySummary.expiresTodayCount,
                          color: _alertColor(ExpiryAlertLevel.expiresToday),
                          isSelected:
                              _selectedLevel == ExpiryAlertLevel.expiresToday,
                          onTap: () => setState(
                            () =>
                                _selectedLevel = ExpiryAlertLevel.expiresToday,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _SummaryBox(
                          label: 'Expired',
                          count: expirySummary.expiredCount,
                          color: _alertColor(ExpiryAlertLevel.expired),
                          isSelected:
                              _selectedLevel == ExpiryAlertLevel.expired,
                          onTap: () => setState(
                            () => _selectedLevel = ExpiryAlertLevel.expired,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Search field
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search pantry...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 10, horizontal: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                ),
              ),

              // Storage location filter chips
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                        label: Text(
                          'All (${allItems.length})',
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: _selectedLocation == 'All',
                        onSelected: (_) =>
                            setState(() => _selectedLocation = 'All'),
                      ),
                    ),
                    ...FoodItem.storageLocations.map((location) {
                      final count = locationCounts[location] ?? 0;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          labelPadding:
                              const EdgeInsets.symmetric(horizontal: 4),
                          avatar: Icon(_locationIcon(location), size: 15),
                          label: Text(
                            '$location ($count)',
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: _selectedLocation == location,
                          onSelected: (_) =>
                              setState(() => _selectedLocation = location),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 4),

              // Food items list
              Expanded(
                child: filteredItems.isEmpty
                    ? Center(
                        child: Text(
                          _emptyFilterMessage(),
                          style: const TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 90),
                        itemCount: filteredItems.length,
                        itemBuilder: (context, index) {
                          final item = filteredItems[index];
                          final level = item.alertLevelAt(referenceNow);
                          final statusLabel = item.statusAt(referenceNow);
                          final daysText = item.daysLeftTextAt(referenceNow);
                          final color = _alertColor(level);
                          final Color? rowTint = switch (level) {
                            ExpiryAlertLevel.normal => null,
                            ExpiryAlertLevel.expiringSoon => null,
                            ExpiryAlertLevel.urgent =>
                              color.withValues(alpha: 0.04),
                            ExpiryAlertLevel.expiresToday =>
                              color.withValues(alpha: 0.06),
                            ExpiryAlertLevel.expired =>
                              color.withValues(alpha: 0.04),
                          };

                          return Dismissible(
                            key: ValueKey(item.id),
                            direction: DismissDirection.horizontal,
                            // Swipe right to consume
                            background: Container(
                              color: Colors.green,
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.only(left: 20),
                              child: const Row(
                                children: [
                                  Icon(Icons.check, color: Colors.white),
                                  SizedBox(width: 8),
                                  Text(
                                    'CONSUMED',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                            // Swipe left to discard
                            secondaryBackground: Container(
                              color: Colors.red,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Text(
                                    'WASTED',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold),
                                  ),
                                  SizedBox(width: 8),
                                  Icon(Icons.delete, color: Colors.white),
                                ],
                              ),
                            ),
                            confirmDismiss: (direction) async {
                              final messenger = _messenger();
                              final action =
                                  direction == DismissDirection.startToEnd
                                      ? 'consumed'
                                      : 'wasted';
                              final qty =
                                  await _promptQuantityIfNeeded(item, action);
                              if (qty == null) return false;
                              return _processItemAction(
                                messenger,
                                item,
                                action: action,
                                quantity: qty,
                              );
                            },
                            child: ListTile(
                              tileColor: rowTint,
                              leading: CircleAvatar(
                                backgroundColor: color.withValues(
                                  alpha: level == ExpiryAlertLevel.normal
                                      ? 0.09
                                      : 0.15,
                                ),
                                child: Icon(
                                  _alertIcon(level),
                                  color: color,
                                ),
                              ),
                              title: Text(item.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${item.category} • Qty ${item.quantity}'
                                    '${item.remainingEstimatedValue != null ? ' • ${formatPkr(item.remainingEstimatedValue!)}' : ''}',
                                  ),
                                  Text('Expires: ${item.expiryText}'),
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _locationColor(
                                              item.storageLocation)
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _locationIcon(item.storageLocation),
                                          size: 13,
                                          color: _locationColor(
                                              item.storageLocation),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          item.storageLocation,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: _locationColor(
                                                item.storageLocation),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              isThreeLine: true,
                              trailing: _buildExpiryTrailing(
                                context,
                                level: level,
                                statusLabel: statusLabel,
                                daysText: daysText,
                                color: color,
                              ),
                              onTap: () =>
                                  _showItemActionSheet(context, item),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
      ),
    );
  }

  Widget _buildExpiryTrailing(
    BuildContext context, {
    required ExpiryAlertLevel level,
    required String statusLabel,
    required String daysText,
    required Color color,
  }) {
    switch (level) {
      case ExpiryAlertLevel.normal:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              statusLabel,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
            Text(
              daysText,
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                fontSize: 11,
              ),
            ),
          ],
        );
      case ExpiryAlertLevel.expiresToday:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.priority_high_rounded,
                size: 14,
                color: Colors.white,
              ),
              const SizedBox(width: 2),
              Text(
                statusLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        );
      case ExpiryAlertLevel.expiringSoon:
      case ExpiryAlertLevel.urgent:
      case ExpiryAlertLevel.expired:
        final isUrgent = level == ExpiryAlertLevel.urgent;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: isUrgent ? 0.18 : 0.13),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: color,
              width: isUrgent ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                statusLabel,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
              Text(
                daysText,
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: isUrgent ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        );
    }
  }
}

class _SummaryBox extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  const _SummaryBox({
    required this.label,
    required this.count,
    required this.color,
    this.isSelected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: isSelected ? 0.22 : 0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? color : Colors.transparent,
              width: 1.6,
            ),
          ),
          child: Column(
            children: [
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    color: color,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class QuantityActionDialog extends StatefulWidget {
  final FoodItem item;
  final String action; // 'consumed' | 'wasted'

  const QuantityActionDialog({
    super.key,
    required this.item,
    required this.action,
  });

  @override
  State<QuantityActionDialog> createState() => _QuantityActionDialogState();
}

class _QuantityActionDialogState extends State<QuantityActionDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '1');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? get _parsedQuantity => int.tryParse(_controller.text.trim());

  bool get _isValid {
    final qty = _parsedQuantity;
    return qty != null && qty >= 1 && qty <= widget.item.quantity;
  }

  String? get _validationError {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      return 'Enter 1 to ${widget.item.quantity}';
    }
    final qty = int.tryParse(raw);
    if (qty == null || qty < 1) {
      return 'Quantity must be at least 1';
    }
    if (qty > widget.item.quantity) {
      return 'Cannot exceed available stock (${widget.item.quantity})';
    }
    return null;
  }

  void _setQuantity(int next) {
    final clamped = next.clamp(1, widget.item.quantity);
    _controller.value = TextEditingValue(
      text: '$clamped',
      selection: TextSelection.collapsed(offset: '$clamped'.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isConsumed = widget.action == 'consumed';
    final maxQty = widget.item.quantity;
    final currentQty = _parsedQuantity;
    final previewValue =
        _isValid ? widget.item.proportionalValueFor(currentQty!) : null;
    final accentColor =
        isConsumed ? Colors.green.shade700 : Colors.red.shade700;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            isConsumed ? Icons.check_circle_outline : Icons.delete_outline,
            color: accentColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isConsumed
                  ? 'Consume ${widget.item.name}'
                  : 'Discard ${widget.item.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Available: $maxQty',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                TextButton(
                  onPressed:
                      currentQty == maxQty ? null : () => _setQuantity(maxQty),
                  child: Text('All ($maxQty)'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Decrease quantity',
                  onPressed: (currentQty != null && currentQty > 1)
                      ? () => _setQuantity(currentQty - 1)
                      : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                SizedBox(
                  width: 92,
                  child: TextField(
                    controller: _controller,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                IconButton(
                  tooltip: 'Increase quantity',
                  onPressed: (currentQty == null || currentQty < maxQty)
                      ? () => _setQuantity((currentQty ?? 0) + 1)
                      : null,
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            if (_validationError != null) ...[
              const SizedBox(height: 8),
              Text(
                _validationError!,
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            if (previewValue != null) ...[
              const SizedBox(height: 10),
              Text(
                isConsumed
                    ? 'Estimated value consumed: ${formatPkr(previewValue)}'
                    : 'Estimated waste cost: ${formatPkr(previewValue)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: accentColor,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: accentColor),
          onPressed: _isValid ? () => Navigator.pop(context, currentQty) : null,
          child: Text(isConsumed ? 'Consume' : 'Discard'),
        ),
      ],
    );
  }
}
