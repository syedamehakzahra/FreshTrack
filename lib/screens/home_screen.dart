import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../models/food_item.dart';
import '../services/food_service.dart';
import 'add_edit_screen.dart';
import 'recipe_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FoodService _service = FoodService();
  String _selectedFilter = 'All'; // 'All', 'Fresh', 'Expiring soon', 'Expired'
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'Expired':
        return Colors.red;
      case 'Expiring soon':
        return Colors.orange;
      default:
        return Colors.green;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'Expired':
        return Icons.error_outline;
      case 'Expiring soon':
        return Icons.warning_amber_rounded;
      default:
        return Icons.check_circle_outline;
    }
  }

  void _showItemActionSheet(BuildContext context, FoodItem item) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _statusColor(item.status).withOpacity(0.15),
                    child: Icon(
                      _statusIcon(item.status),
                      color: _statusColor(item.status),
                    ),
                  ),
                  title: Text(item.name,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      '${item.category} • Qty: ${item.quantity} • ${item.daysLeftText}'),
                ),
                const Divider(),
                ListTile(
                  leading:
                      const Icon(Icons.check_circle_outline, color: Colors.green),
                  title: const Text('Mark as Consumed / Eaten'),
                  subtitle: const Text('Logs to stats as saved food'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _service.markAsConsumed(item);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('🎉 Marked "${item.name}" as consumed!'),
                        backgroundColor: Colors.green.shade700,
                      ),
                    );
                  },
                ),
                ListTile(
                  leading:
                      const Icon(Icons.delete_outline, color: Colors.redAccent),
                  title: const Text('Mark as Wasted / Discarded'),
                  subtitle: const Text('Logs to food waste statistics'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _service.markAsWasted(item);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('🗑️ Marked "${item.name}" as discarded.'),
                        backgroundColor: Colors.red.shade700,
                      ),
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
                        builder: (_) => const RecipeScreen(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Edit Item Details'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AddEditScreen(item: item),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Pantry'),
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AddEditScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Add item'),
      ),
      body: StreamBuilder<List<FoodItem>>(
        stream: _service.streamItems(),
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

          final expired = allItems.where((i) => i.status == 'Expired').length;
          final soon = allItems.where((i) => i.status == 'Expiring soon').length;
          final fresh = allItems.where((i) => i.status == 'Fresh').length;

          // Filter by selected tab and search
          final filteredItems = allItems.where((item) {
            final matchesFilter = _selectedFilter == 'All' ||
                item.status == _selectedFilter;
            final matchesSearch = _searchQuery.isEmpty ||
                item.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                item.category
                    .toLowerCase()
                    .contains(_searchQuery.toLowerCase());
            return matchesFilter && matchesSearch;
          }).toList();

          return Column(
            children: [
              // Expiry Reminder Banner (Alerts user about items expiring soon)
              if (soon > 0 || expired > 0)
                Container(
                  margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: (soon > 0 ? Colors.orange : Colors.red)
                        .withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: (soon > 0 ? Colors.orange : Colors.red)
                          .withOpacity(0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        soon > 0
                            ? Icons.notifications_active_outlined
                            : Icons.warning_amber_rounded,
                        color: soon > 0 ? Colors.orange.shade800 : Colors.red,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          soon > 0
                              ? '$soon item(s) expiring soon! Use them or check recipes.'
                              : '$expired item(s) have expired.',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color:
                                soon > 0 ? Colors.orange.shade900 : Colors.red.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // Summary row at the top (Tap a box to filter!)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    _SummaryBox(
                      label: 'All',
                      count: allItems.length,
                      color: Colors.blueGrey,
                      isSelected: _selectedFilter == 'All',
                      onTap: () => setState(() => _selectedFilter = 'All'),
                    ),
                    const SizedBox(width: 6),
                    _SummaryBox(
                      label: 'Fresh',
                      count: fresh,
                      color: Colors.green,
                      isSelected: _selectedFilter == 'Fresh',
                      onTap: () => setState(() => _selectedFilter = 'Fresh'),
                    ),
                    const SizedBox(width: 6),
                    _SummaryBox(
                      label: 'Soon',
                      count: soon,
                      color: Colors.orange,
                      isSelected: _selectedFilter == 'Expiring soon',
                      onTap: () =>
                          setState(() => _selectedFilter = 'Expiring soon'),
                    ),
                    const SizedBox(width: 6),
                    _SummaryBox(
                      label: 'Expired',
                      count: expired,
                      color: Colors.red,
                      isSelected: _selectedFilter == 'Expired',
                      onTap: () => setState(() => _selectedFilter = 'Expired'),
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

              // Food items list
              Expanded(
                child: filteredItems.isEmpty
                    ? Center(
                        child: Text(
                          _searchQuery.isNotEmpty
                              ? 'No food items matching "$_searchQuery".'
                              : 'No $_selectedFilter items found.',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 90),
                        itemCount: filteredItems.length,
                        itemBuilder: (context, index) {
                          final item = filteredItems[index];
                          final color = _statusColor(item.status);

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
                              if (direction == DismissDirection.startToEnd) {
                                await _service.markAsConsumed(item);
                                if (!context.mounted) return false;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('🎉 Consumed "${item.name}"!'),
                                    backgroundColor: Colors.green.shade700,
                                  ),
                                );
                                return true;
                              } else {
                                await _service.markAsWasted(item);
                                if (!context.mounted) return false;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content:
                                        Text('🗑️ Discarded "${item.name}".'),
                                    backgroundColor: Colors.red.shade700,
                                  ),
                                );
                                return true;
                              }
                            },
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: color.withOpacity(0.15),
                                child: Icon(_statusIcon(item.status),
                                    color: color),
                              ),
                              title: Text(item.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                '${item.category} • Qty ${item.quantity}\n'
                                'Expires: ${item.expiryText}',
                              ),
                              isThreeLine: true,
                              trailing: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: color.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: color),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      item.status,
                                      style: TextStyle(
                                        color: color,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      item.daysLeftText,
                                      style:
                                          TextStyle(color: color, fontSize: 10),
                                    ),
                                  ],
                                ),
                              ),
                              onTap: () => _showItemActionSheet(context, item),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
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
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: color.withOpacity(isSelected ? 0.25 : 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? color : Colors.transparent,
              width: 1.8,
            ),
          ),
          child: Column(
            children: [
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
