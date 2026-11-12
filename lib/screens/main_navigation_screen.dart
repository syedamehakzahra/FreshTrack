import 'package:flutter/material.dart';
import '../services/user_service.dart';
import 'home_screen.dart';
import 'recipe_screen.dart';
import 'shopping_screen.dart';
import 'stats_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  final String userId;
  final List<Widget>? screensOverride;
  final bool ensureUserDocument;

  const MainNavigationScreen({
    super.key,
    required this.userId,
    this.screensOverride,
    this.ensureUserDocument = true,
  });

  static const List<String> tabLabels = [
    'Pantry',
    'Shopping',
    'Recipes',
    'Stats',
  ];

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  UserService? _userService;

  late List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = widget.screensOverride ?? _buildScreens(widget.userId);
    if (widget.ensureUserDocument) {
      _userService = UserService();
      _userService!.ensureUserDocumentIfMissing(widget.userId);
    }
  }

  @override
  void didUpdateWidget(covariant MainNavigationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.screensOverride != widget.screensOverride) {
      _currentIndex = 0;
      _screens = widget.screensOverride ?? _buildScreens(widget.userId);
      if (widget.ensureUserDocument) {
        _userService ??= UserService();
        _userService!.ensureUserDocumentIfMissing(widget.userId);
      }
    }
  }

  List<Widget> _buildScreens(String uid) => [
        HomeScreen(userId: uid),
        ShoppingScreen(userId: uid),
        RecipeScreen(userId: uid),
        StatsScreen(userId: uid),
      ];

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: _screens,
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            setState(() => _currentIndex = index);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.kitchen_outlined),
              selectedIcon: Icon(Icons.kitchen),
              label: 'Pantry',
            ),
            NavigationDestination(
              icon: Icon(Icons.shopping_cart_outlined),
              selectedIcon: Icon(Icons.shopping_cart),
              label: 'Shopping',
            ),
            NavigationDestination(
              icon: Icon(Icons.menu_book_outlined),
              selectedIcon: Icon(Icons.menu_book),
              label: 'Recipes',
            ),
            NavigationDestination(
              icon: Icon(Icons.analytics_outlined),
              selectedIcon: Icon(Icons.analytics),
              label: 'Stats',
            ),
          ],
        ),
      ),
    );
  }
}
