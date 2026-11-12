import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:freshtrack/models/food_item.dart';
import 'package:freshtrack/models/shopping_item.dart';
import 'package:freshtrack/models/waste_log.dart';
import 'package:freshtrack/screens/add_edit_screen.dart';
import 'package:freshtrack/screens/home_screen.dart';
import 'package:freshtrack/screens/main_navigation_screen.dart';
import 'package:freshtrack/screens/recipe_screen.dart';
import 'package:freshtrack/screens/shopping_screen.dart';
import 'package:freshtrack/services/recipe_service.dart';
import 'package:freshtrack/services/shopping_service.dart';
import 'package:freshtrack/utils/price_formatter.dart';

class _FailingShoppingService extends ShoppingService {
  _FailingShoppingService({super.userId});

  @override
  Future<void> updateQuantity(ShoppingItem item, int quantity) async {
    throw StateError('Simulated quantity error');
  }

  @override
  Future<void> deleteItem(String id) async {}

  @override
  Future<ShoppingAddResult> addOrMergeItem({
    required String name,
    String category = 'Other',
    String storageLocation = FoodItem.defaultStorageLocation,
    int quantity = 1,
    String source = ShoppingItem.sourceManual,
  }) async {
    throw StateError('Simulated undo error');
  }
}

void main() {
  group('FoodItem Model Tests', () {
    test('Follows official expiry alert schedule across all day thresholds', () {
      final refNow = DateTime(2026, 11, 11, 14, 30);
      FoodItem buildAtDays(int daysOffset) => FoodItem(
            id: 'item_$daysOffset',
            name: 'Item $daysOffset',
            category: 'Dairy',
            quantity: 1,
            expiryDate: DateTime(2026, 11, 11).add(Duration(days: daysOffset)),
          );

      // > 7 days: Normal
      expect(buildAtDays(10).daysLeftAt(refNow), 10);
      expect(buildAtDays(10).statusAt(refNow), 'Normal');
      expect(
        buildAtDays(10).alertLevelAt(refNow),
        ExpiryAlertLevel.normal,
      );
      expect(buildAtDays(8).daysLeftAt(refNow), 8);
      expect(buildAtDays(8).statusAt(refNow), 'Normal');
      expect(
        buildAtDays(8).alertLevelAt(refNow),
        ExpiryAlertLevel.normal,
      );

      // 4 to 7 days: Expiring Soon
      expect(buildAtDays(7).daysLeftAt(refNow), 7);
      expect(buildAtDays(7).statusAt(refNow), 'Expiring Soon');
      expect(
        buildAtDays(7).alertLevelAt(refNow),
        ExpiryAlertLevel.expiringSoon,
      );
      expect(buildAtDays(4).daysLeftAt(refNow), 4);
      expect(buildAtDays(4).statusAt(refNow), 'Expiring Soon');
      expect(
        buildAtDays(4).alertLevelAt(refNow),
        ExpiryAlertLevel.expiringSoon,
      );

      // 1 to 3 days: Urgent
      expect(buildAtDays(3).daysLeftAt(refNow), 3);
      expect(buildAtDays(3).statusAt(refNow), 'Urgent');
      expect(buildAtDays(3).alertLevelAt(refNow), ExpiryAlertLevel.urgent);
      expect(buildAtDays(1).daysLeftAt(refNow), 1);
      expect(buildAtDays(1).statusAt(refNow), 'Urgent');
      expect(buildAtDays(1).daysLeftTextAt(refNow), '1 day left');

      // 0 days: Expires Today
      expect(buildAtDays(0).daysLeftAt(refNow), 0);
      expect(buildAtDays(0).statusAt(refNow), 'Expires Today');
      expect(
        buildAtDays(0).alertLevelAt(refNow),
        ExpiryAlertLevel.expiresToday,
      );
      expect(buildAtDays(0).daysLeftTextAt(refNow), 'Expires Today');

      // < 0 days: Expired
      expect(buildAtDays(-1).daysLeftAt(refNow), -1);
      expect(buildAtDays(-1).statusAt(refNow), 'Expired');
      expect(buildAtDays(-1).alertLevelAt(refNow), ExpiryAlertLevel.expired);
      expect(buildAtDays(-1).daysLeftTextAt(refNow), 'Expired 1 day ago');
    });

    test('Uses calendar-date comparison across midnight, timezone, and DST boundaries without mutating expiryDate', () {
      // Only 10 minutes apart across midnight -> must still count as 1 full calendar day (Urgent).
      final lateNight = DateTime(2026, 11, 11, 23, 55);
      final earlyNextDay = DateTime(2026, 11, 12, 0, 5);
      final nextDayItem = FoodItem(
        id: 'midnight_next',
        name: 'Milk',
        category: 'Dairy',
        quantity: 1,
        expiryDate: earlyNextDay,
      );
      expect(nextDayItem.daysLeftAt(lateNight), 1);
      expect(nextDayItem.statusAt(lateNight), 'Urgent');
      expect(nextDayItem.expiryDate, earlyNextDay); // Original stored value untouched.

      // Only 10 minutes past midnight -> immediately overdue (-1 day, Expired).
      final earlyToday = DateTime(2026, 11, 12, 0, 5);
      final lateYesterday = DateTime(2026, 11, 11, 23, 55);
      final yesterdayItem = FoodItem(
        id: 'midnight_prev',
        name: 'Yogurt',
        category: 'Dairy',
        quantity: 1,
        expiryDate: lateYesterday,
      );
      expect(yesterdayItem.daysLeftAt(earlyToday), -1);
      expect(yesterdayItem.statusAt(earlyToday), 'Expired');

      // UTC DateTime converts to local calendar date before computing difference.
      final utcExpiry = DateTime.utc(2026, 11, 15, 22, 30);
      final localExpiry = utcExpiry.toLocal();
      final utcItem = FoodItem(
        id: 'utc_1',
        name: 'Cheese',
        category: 'Dairy',
        quantity: 1,
        expiryDate: utcExpiry,
      );
      final refSameLocalDay = DateTime(
        localExpiry.year,
        localExpiry.month,
        localExpiry.day,
        23,
        59,
      );
      expect(utcItem.daysLeftAt(refSameLocalDay), 0);
      expect(utcItem.statusAt(refSameLocalDay), 'Expires Today');

      // DST month boundary sanity check (e.g. March spring-forward week stays exact).
      final marchStart = DateTime(2026, 3, 7, 10, 0);
      final marchItem = FoodItem(
        id: 'dst_1',
        name: 'Eggs',
        category: 'Dairy',
        quantity: 1,
        expiryDate: DateTime(2026, 3, 14),
      );
      expect(marchItem.daysLeftAt(marchStart), 7);
      expect(marchItem.statusAt(marchStart), 'Expiring Soon');

      // Live getters relative to DateTime.now() follow the same schedule.
      final liveExpired = FoodItem(
        id: 'live_exp',
        name: 'Juice',
        category: 'Drinks',
        quantity: 1,
        expiryDate: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(liveExpired.status, 'Expired');
      expect(liveExpired.daysLeft, -1);
    });

    test('Deserializes legacy and sparse Firestore maps safely', () {
      final expiry = DateTime(2026, 12, 20);
      final fullItem = FoodItem.fromMap('doc_1', {
        'name': 'Cheese',
        'category': 'Dairy',
        'quantity': 2.0,
        'expiryDate': expiry,
      });
      expect(fullItem.id, 'doc_1');
      expect(fullItem.name, 'Cheese');
      expect(fullItem.category, 'Dairy');
      expect(fullItem.storageLocation, FoodItem.defaultStorageLocation);
      expect(fullItem.quantity, 2);
      expect(fullItem.expiryDate, expiry);
      expect(fullItem.toMap()['storageLocation'], 'Pantry');

      final sparseItem = FoodItem.fromMap('doc_2', const {});
      expect(sparseItem.id, 'doc_2');
      expect(sparseItem.name, '');
      expect(sparseItem.category, 'Other');
      expect(sparseItem.storageLocation, 'Pantry');
      expect(sparseItem.quantity, 1);
    });

    test('Normalizes and persists storageLocation values safely', () {
      final expiry = DateTime(2026, 12, 20);
      final fridgeItem = FoodItem.fromMap('doc_3', {
        'name': 'Milk',
        'category': 'Dairy',
        'storageLocation': 'fridge',
        'quantity': 1,
        'expiryDate': expiry,
      });
      expect(fridgeItem.storageLocation, 'Fridge');
      expect(fridgeItem.toMap()['storageLocation'], 'Fridge');

      final freezerItem = FoodItem.fromMap('doc_4', {
        'name': 'Peas',
        'category': 'Frozen',
        'storageLocation': 'Freezer',
        'quantity': 2,
        'expiryDate': expiry,
      });
      expect(freezerItem.storageLocation, 'Freezer');

      final unknownLocationItem = FoodItem.fromMap('doc_5', {
        'name': 'Rice',
        'category': 'Other',
        'storageLocation': 'Garage',
        'quantity': 1,
        'expiryDate': expiry,
      });
      expect(unknownLocationItem.storageLocation, 'Pantry');
    });

    test('Calculates unit value and proportional values accurately', () {
      final item = FoodItem(
        id: 'doc_6',
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
        originalQuantity: 2,
        totalPrice: 500,
        expiryDate: DateTime(2026, 12, 20),
      );

      expect(item.estimatedUnitPrice, 250.0);
      expect(item.proportionalValueFor(1), 250.0);
      expect(item.proportionalValueFor(2), 500.0);
      expect(formatPkr(item.proportionalValueFor(1)!), 'Rs. 250');

      final unpriced = FoodItem(
        id: 'doc_7',
        name: 'Water',
        category: 'Drinks',
        quantity: 2,
        totalPrice: 0,
        expiryDate: DateTime(2026, 12, 20),
      );
      expect(unpriced.totalPrice, isNull);
      expect(unpriced.proportionalValueFor(1), isNull);
    });

    test('buildForSave preserves baseline unless quantity or price changes', () {
      final expiry = DateTime(2026, 12, 20);
      final partiallyConsumed = FoodItem(
        id: 'milk_1',
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 3,
        originalQuantity: 4,
        totalPrice: 1000,
        expiryDate: expiry,
      );

      // Editing unrelated fields preserves originalQuantity (4) and unit value (250).
      final renamed = FoodItem.buildForSave(
        existing: partiallyConsumed,
        name: 'Fresh Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 3,
        totalPrice: 1000,
        expiryDate: expiry,
      );
      expect(renamed.quantity, 3);
      expect(renamed.originalQuantity, 4);
      expect(renamed.estimatedUnitPrice, 250.0);

      // Editing totalPrice establishes a new baseline for remaining stock.
      final repriced = FoodItem.buildForSave(
        existing: partiallyConsumed,
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 3,
        totalPrice: 600,
        expiryDate: expiry,
      );
      expect(repriced.quantity, 3);
      expect(repriced.originalQuantity, 3);
      expect(repriced.estimatedUnitPrice, 200.0);

      // Editing remaining quantity resets baseline to the new quantity.
      final restocked = FoodItem.buildForSave(
        existing: partiallyConsumed,
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 5,
        totalPrice: 1000,
        expiryDate: expiry,
      );
      expect(restocked.quantity, 5);
      expect(restocked.originalQuantity, 5);
      expect(restocked.estimatedUnitPrice, 200.0);

      // Clearing price sets explicit null in toMap() so Firestore clears it.
      final unpriced = FoodItem.buildForSave(
        existing: partiallyConsumed,
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 3,
        totalPrice: null,
        expiryDate: expiry,
      );
      expect(unpriced.totalPrice, isNull);
      expect(unpriced.toMap().containsKey('totalPrice'), isTrue);
      expect(unpriced.toMap()['totalPrice'], isNull);

      expect(
        () => FoodItem.buildForSave(
          name: 'Invalid',
          category: 'Other',
          storageLocation: 'Pantry',
          quantity: 0,
          expiryDate: expiry,
        ),
        throwsArgumentError,
      );
    });
  });

  group('Partial Quantity & Pricing UI Tests', () {
    testWidgets('QuantityActionDialog validates stock bounds and shows value',
        (tester) async {
      final milk = FoodItem(
        id: 'milk_1',
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 4,
        originalQuantity: 4,
        totalPrice: 1000,
        expiryDate: DateTime(2026, 12, 20),
      );

      int? dialogResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  dialogResult = await showDialog<int>(
                    context: context,
                    builder: (_) => QuantityActionDialog(
                      item: milk,
                      action: 'consumed',
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Consume Milk'), findsOneWidget);
      expect(find.text('Available: 4'), findsOneWidget);
      expect(find.text('Estimated value consumed: Rs. 250'), findsOneWidget);

      await tester.tap(find.byTooltip('Increase quantity'));
      await tester.pump();
      expect(find.text('Estimated value consumed: Rs. 500'), findsOneWidget);

      // Entering value above stock disables submission cleanly.
      await tester.enterText(find.byType(TextField), '5');
      await tester.pump();
      expect(find.text('Cannot exceed available stock (4)'), findsOneWidget);
      final consumeBtnInvalid =
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Consume'));
      expect(consumeBtnInvalid.onPressed, isNull);

      // Entering 0 also fails validation.
      await tester.enterText(find.byType(TextField), '0');
      await tester.pump();
      expect(find.text('Quantity must be at least 1'), findsOneWidget);

      // Quick All button selects max stock and returns 4 cleanly.
      await tester.tap(find.text('All (4)'));
      await tester.pump();
      expect(find.text('Estimated value consumed: Rs. 1,000'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Consume'));
      await tester.pumpAndSettle();
      expect(dialogResult, 4);
    });

    testWidgets('AddEditScreen validates optional price and shows partial baseline note',
        (tester) async {
      final partiallyUsedMilk = FoodItem(
        id: 'milk_2',
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 3,
        originalQuantity: 4,
        totalPrice: 1000,
        expiryDate: DateTime(2026, 12, 20),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AddEditScreen(item: partiallyUsedMilk, userId: 'uid_test'),
        ),
      );

      expect(
        find.textContaining('Original entry: 4 units • Rs. 1,000 (Rs. 250/unit)'),
        findsOneWidget,
      );

      final priceField = find.widgetWithText(
        TextFormField,
        'Total price (Rs., optional)',
      );
      await tester.enterText(priceField, '600');
      await tester.pump();
      expect(
        find.textContaining('New baseline on save: 3 unit(s) at Rs. 600 (Rs. 200/unit)'),
        findsOneWidget,
      );

      // Invalid zero price shows validation error on save.
      await tester.enterText(priceField, '0');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await tester.pump();
      expect(
        find.text('Enter a valid price above 0 or leave blank'),
        findsOneWidget,
      );
    });
  });

  group('Shopping List & Navigation UI Tests', () {
    testWidgets('MainNavigationScreen renders tabs in order Pantry | Shopping | Recipes | Stats',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MainNavigationScreen(
            userId: 'uid_test',
            ensureUserDocument: false,
            screensOverride: [
              Center(child: Text('Pantry Tab')),
              Center(child: Text('Shopping Tab')),
              Center(child: Text('Recipes Tab')),
              Center(child: Text('Stats Tab')),
            ],
          ),
        ),
      );

      final destinations = tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .map((d) => d.label)
          .toList();
      expect(destinations, ['Pantry', 'Shopping', 'Recipes', 'Stats']);

      await tester.tap(find.text('Shopping'));
      await tester.pumpAndSettle();
      final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 1);
    });

    testWidgets('ShoppingScreen displays Buy Again chips, checked Move to Pantry bar, and Pantry hints',
        (tester) async {
      final milkShop = ShoppingItem(
        id: ShoppingItem.docIdForName('Milk'),
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
        isChecked: true,
      );
      final yogurtLog = WasteLog(
        id: 'log_1',
        foodName: 'Yogurt',
        category: 'Dairy',
        quantity: 2,
        action: 'consumed',
        timestamp: DateTime(2026, 11, 9),
      );
      final milkLog = WasteLog(
        id: 'log_2',
        foodName: 'Milk',
        category: 'Dairy',
        quantity: 1,
        action: 'wasted',
        timestamp: DateTime(2026, 11, 10),
      );
      final pantryMilk = FoodItem(
        id: 'p_1',
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 1,
        expiryDate: DateTime(2026, 11, 20),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ShoppingScreen(
            userId: 'uid_test',
            shoppingStream: Stream.value([milkShop]),
            pantryStream: Stream.value([pantryMilk]),
            logsStream: Stream.value([yogurtLog, milkLog]),
            onLogout: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Yogurt appears in Buy Again; Milk is omitted because it's already queued.
      expect(find.text('Buy Again'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Yogurt'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Milk'), findsNothing);

      // Checked bar & list card appear properly.
      expect(find.text('1 checked'), findsOneWidget);
      expect(find.text('Move to Pantry'), findsOneWidget);
      expect(find.text('Milk'), findsOneWidget);
      expect(find.text('Qty 2'), findsOneWidget);
      expect(find.text('In pantry'), findsOneWidget);
      expect(find.text('Restock'), findsOneWidget);
    });

    testWidgets('ShoppingItemFormDialog warns about duplicate normalized name before merging',
        (tester) async {
      final existingMilk = ShoppingItem(
        id: ShoppingItem.docIdForName('Milk'),
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
      );

      ShoppingItemDraft? submitted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  submitted = await showDialog<ShoppingItemDraft>(
                    context: context,
                    builder: (_) =>
                        ShoppingItemFormDialog(currentItems: [existingMilk]),
                  );
                },
                child: const Text('Open Form'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Form'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Food name'),
        '  milk  ',
      );
      await tester.pump();
      expect(
        find.text('Already on list (Qty 2) — saving will combine quantities.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(submitted, isNotNull);
      expect(submitted!.name, 'milk');
      expect(submitted!.quantity, 1);
    });

    testWidgets('BulkRestockDialog requires explicit expiry date before submitting',
        (tester) async {
      final eggs = ShoppingItem(
        id: ShoppingItem.docIdForName('Eggs'),
        name: 'Eggs',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
        isChecked: true,
      );

      var submitCalled = false;
      List<RestockEntry>? submittedEntries;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showDialog<RestockResult>(
                    context: context,
                    builder: (_) => BulkRestockDialog(
                      items: [eggs],
                      pantryNormalizedNames: const {},
                      referenceNow: DateTime(2026, 11, 10),
                      onSubmit: (entries) async {
                        submitCalled = true;
                        submittedEntries = entries;
                        return const RestockResult(
                          restockedCount: 1,
                          mergedPantryCount: 0,
                          createdPantryCount: 1,
                        );
                      },
                    ),
                  );
                },
                child: const Text('Restock Checked'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Restock Checked'));
      await tester.pumpAndSettle();

      // Submitting without expiry date must block cleanly and show error.
      await tester.tap(find.widgetWithText(FilledButton, 'Move to Pantry'));
      await tester.pump();
      expect(submitCalled, isFalse);
      expect(find.text('Expiry date is required'), findsOneWidget);
      expect(
        find.text('Please choose a valid expiry date for every checked item.'),
        findsOneWidget,
      );

      // Pick expiry date via date picker (confirm today), enter Rs. 450, then submit.
      await tester.tap(find.text('Choose expiry date *'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Total price (Rs., optional)'),
        '450',
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Move to Pantry'));
      await tester.pumpAndSettle();

      expect(submitCalled, isTrue);
      expect(submittedEntries, hasLength(1));
      expect(submittedEntries!.first.quantity, 2);
      expect(submittedEntries!.first.totalPrice, 450.0);
      expect(submittedEntries!.first.expiryDate, DateTime(2026, 11, 10));
    });

    testWidgets('AddEditScreen in restock mode requires expiry date and shows Pantry hint',
        (tester) async {
      final shopBread = ShoppingItem(
        id: ShoppingItem.docIdForName('Bread'),
        name: 'Bread',
        category: 'Bakery',
        storageLocation: 'Pantry',
        quantity: 2,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AddEditScreen(
            userId: 'uid_test',
            fromShoppingItem: shopBread,
            alreadyInPantryHint: true,
          ),
        ),
      );

      expect(find.text('Move to Pantry'), findsOneWidget);
      expect(find.text('Bread'), findsOneWidget);
      expect(find.text('Choose expiry date *'), findsOneWidget);
      expect(
        find.textContaining('is already in your Pantry'),
        findsOneWidget,
      );

      // Tapping Add to Pantry without expiry date shows inline validation error.
      final addButton = find.widgetWithText(FilledButton, 'Add to Pantry');
      await tester.ensureVisible(addButton);
      await tester.pumpAndSettle();
      await tester.tap(addButton);
      await tester.pump();
      expect(find.text('Please choose an expiry date'), findsWidgets);
    });

    testWidgets('BulkRestockDialog prunes committed items on PartialRestockException and retries remaining only',
        (tester) async {
      final milk = ShoppingItem(
        id: ShoppingItem.docIdForName('Milk'),
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
        isChecked: true,
      );
      final eggs = ShoppingItem(
        id: ShoppingItem.docIdForName('Eggs'),
        name: 'Eggs',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 1,
        isChecked: true,
      );
      final bread = ShoppingItem(
        id: ShoppingItem.docIdForName('Bread'),
        name: 'Bread',
        category: 'Bakery',
        storageLocation: 'Pantry',
        quantity: 1,
        isChecked: true,
      );

      final callBatches = <List<String>>[];
      RestockResult? dialogResult;
      var callCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  dialogResult = await showDialog<RestockResult>(
                    context: context,
                    builder: (_) => BulkRestockDialog(
                      items: [milk, eggs, bread],
                      referenceNow: DateTime(2026, 11, 10),
                      onSubmit: (entries) async {
                        callCount++;
                        callBatches.add(
                          entries.map((e) => e.shoppingItem.name).toList(),
                        );
                        if (callCount == 1) {
                          throw PartialRestockException(
                            completedResult: const RestockResult(
                              restockedCount: 2,
                              mergedPantryCount: 0,
                              createdPantryCount: 2,
                            ),
                            completedShoppingIds: [milk.id, eggs.id],
                            remainingEntries: [entries.last],
                            cause: 'Chunk 2 offline',
                          );
                        }
                        return const RestockResult(
                          restockedCount: 1,
                          mergedPantryCount: 0,
                          createdPantryCount: 1,
                        );
                      },
                    ),
                  );
                },
                child: const Text('Open Bulk'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Bulk'));
      await tester.pumpAndSettle();

      expect(find.text('Move 3 Item(s) to Pantry'), findsOneWidget);

      // Apply today's expiry date to all unset rows at once.
      await tester.tap(find.text('Set date for all unset items'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // First submit: Milk & Eggs succeed, Bread fails in chunk 2.
      await tester.tap(find.widgetWithText(FilledButton, 'Move to Pantry'));
      await tester.pumpAndSettle();

      expect(callBatches, [
        ['Milk', 'Eggs', 'Bread'],
      ]);
      // Completed rows pruned; dialog updates to remaining 1 item ('Bread').
      expect(find.text('Move 1 Item(s) to Pantry'), findsOneWidget);
      expect(
        find.text(
          '2 item(s) already moved to Pantry and removed from this batch.',
        ),
        findsOneWidget,
      );
      expect(find.text('Milk'), findsNothing);
      expect(find.text('Eggs'), findsNothing);
      expect(find.text('Bread'), findsOneWidget);
      expect(find.text('Retry Remaining (1)'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);

      // Retry submits ONLY remaining ['Bread'] and returns combined 3 total.
      await tester.tap(find.widgetWithText(FilledButton, 'Retry Remaining (1)'));
      await tester.pumpAndSettle();

      expect(callBatches, [
        ['Milk', 'Eggs', 'Bread'],
        ['Bread'],
      ]);
      expect(dialogResult, isNotNull);
      expect(dialogResult!.restockedCount, 3);
      expect(dialogResult!.createdPantryCount, 3);
      expect(dialogResult!.mergedPantryCount, 0);
    });
  });

  group('Phase 1 & Phase 3 UI Hardening Tests', () {
    testWidgets('ShoppingScreen catches async errors on steppers and swipe-delete Undo',
        (tester) async {
      final milk = ShoppingItem(
        id: ShoppingItem.docIdForName('Milk'),
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
      );
      final failingService = _FailingShoppingService(userId: 'uid_test');

      await tester.pumpWidget(
        MaterialApp(
          home: ShoppingScreen(
            userId: 'uid_test',
            shoppingService: failingService,
            shoppingStream: Stream.value([milk]),
            pantryStream: Stream.value(const []),
            logsStream: Stream.value(const []),
            onLogout: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Stepper increment failure shows SnackBar without crashing with unhandled Future.
      await tester.tap(find.byTooltip('Increase quantity'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not update "Milk" quantity'),
        findsOneWidget,
      );

      // Stepper decrement failure also handled gracefully.
      await tester.tap(find.byTooltip('Decrease quantity'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not update "Milk" quantity'),
        findsOneWidget,
      );

      // Swipe delete + Undo failure displays clear restore error SnackBar.
      await tester.drag(find.byKey(ValueKey(milk.id)), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not restore "Milk"'),
        findsOneWidget,
      );
    });

    testWidgets('HomeScreen displays all alert categories accurately without double-counting and confirms logout',
        (tester) async {
      final fixedNow = DateTime(2026, 11, 11, 10, 0);
      final items = [
        FoodItem(
          id: 'exp_1',
          name: 'Yogurt',
          category: 'Dairy',
          storageLocation: 'Fridge',
          quantity: 1,
          expiryDate: DateTime(2026, 11, 9), // -2 days -> Expired
        ),
        FoodItem(
          id: 'today_1',
          name: 'Spinach',
          category: 'Vegetables',
          storageLocation: 'Fridge',
          quantity: 1,
          expiryDate: DateTime(2026, 11, 11), // 0 days -> Expires Today
        ),
        FoodItem(
          id: 'urgent_1',
          name: 'Milk',
          category: 'Dairy',
          storageLocation: 'Fridge',
          quantity: 2,
          expiryDate: DateTime(2026, 11, 13), // 2 days -> Urgent
        ),
        FoodItem(
          id: 'soon_1',
          name: 'Apples',
          category: 'Fruits',
          storageLocation: 'Pantry',
          quantity: 4,
          expiryDate: DateTime(2026, 11, 16), // 5 days -> Expiring Soon
        ),
        FoodItem(
          id: 'normal_1',
          name: 'Rice',
          category: 'Other',
          storageLocation: 'Pantry',
          quantity: 1,
          expiryDate: DateTime(2026, 11, 25), // 14 days -> Normal
        ),
      ];
      var loggedOut = false;

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            userId: 'uid_test',
            itemsStream: Stream.value(items),
            nowProvider: () => fixedNow,
            onLogout: () => loggedOut = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Banner displays every active alert category simultaneously without hiding any.
      expect(
        find.text(
          '1 expired, 1 expiring today, 1 urgent, and 1 expiring soon — review items or check recipes.',
        ),
        findsOneWidget,
      );
      // Expired and urgent items near top are immediately visible in Pantry.
      expect(find.text('Yogurt'), findsOneWidget);
      expect(find.text('Expired 2 days ago'), findsOneWidget);
      expect(find.text('Spinach'), findsOneWidget);
      expect(find.text('Expires Today'), findsNWidgets(2));
      expect(find.text('Milk'), findsOneWidget);
      expect(find.text('2 days left'), findsOneWidget);

      // Scroll All list to verify remaining items and tier badges below the fold.
      await tester.scrollUntilVisible(
        find.text('Apples'),
        150,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Apples'), findsOneWidget);
      expect(find.text('5 days left'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Rice'),
        150,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Rice'), findsOneWidget);
      expect(find.text('14 days left'), findsOneWidget);

      // Summary box tap filters accurately to exact non-overlapping categories.
      await tester.tap(find.text('Urgent').first);
      await tester.pump();
      expect(find.text('Milk'), findsOneWidget);
      expect(find.text('Apples'), findsNothing);
      expect(find.text('Yogurt'), findsNothing);

      await tester.tap(find.text('Expiring Soon').first);
      await tester.pump();
      expect(find.text('Apples'), findsOneWidget);
      expect(find.text('Milk'), findsNothing);

      await tester.tap(find.text('Expires Today').first);
      await tester.pump();
      expect(find.text('Spinach'), findsOneWidget);
      expect(find.text('Apples'), findsNothing);

      await tester.tap(find.text('Expired').first);
      await tester.pump();
      expect(find.text('Yogurt'), findsOneWidget);
      expect(find.text('Spinach'), findsNothing);

      await tester.tap(find.text('Normal').first);
      await tester.pump();
      expect(find.text('Rice'), findsOneWidget);
      expect(find.text('14 days left'), findsOneWidget);
      expect(find.text('Yogurt'), findsNothing);

      await tester.tap(find.text('All').first);
      await tester.pump();
      expect(find.text('Yogurt'), findsOneWidget);

      // Logout requires confirmation before signing out.
      await tester.tap(find.byTooltip('Logout'));
      await tester.pumpAndSettle();
      expect(find.text('Logout?'), findsOneWidget);
      expect(loggedOut, isFalse);

      await tester.tap(find.widgetWithText(FilledButton, 'Logout'));
      await tester.pumpAndSettle();
      expect(loggedOut, isTrue);
    });

    testWidgets('HomeScreen dynamically updates status when calendar day changes on resume without deleting expired items',
        (tester) async {
      var currentNow = DateTime(2026, 11, 11, 23, 50);
      final storedExpiry = DateTime(2026, 11, 12);
      final milk = FoodItem(
        id: 'rollover_milk',
        name: 'Fresh Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
        expiryDate: storedExpiry,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            userId: 'uid_test',
            itemsStream: Stream.value([milk]),
            nowProvider: () => currentNow,
            onLogout: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Day 0 (Nov 11 23:50): 1 day left -> Urgent
      expect(find.text('1 day left'), findsOneWidget);
      expect(
        find.text('1 urgent item (1–3 days left) — use soon or check recipes.'),
        findsOneWidget,
      );

      // Advance past midnight to Nov 12 00:05 and resume app.
      currentNow = DateTime(2026, 11, 12, 0, 5);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('Expires Today'), findsNWidgets(2));
      expect(
        find.text('1 item expires today — use today or check recipes.'),
        findsOneWidget,
      );

      // Advance to Nov 13 00:05 and resume app -> Expired, still stays in Pantry!
      currentNow = DateTime(2026, 11, 13, 0, 5);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('Fresh Milk'), findsOneWidget);
      expect(find.text('Expired 1 day ago'), findsOneWidget);
      expect(
        find.text('1 item has expired — review, use if safe, or discard.'),
        findsOneWidget,
      );
      expect(milk.expiryDate, storedExpiry);
    });

    testWidgets('RecipeScreen deduplicates Pantry ingredient chips and excludes expired items',
        (tester) async {
      final now = DateTime.now();
      final mockClient = MockClient((_) async {
        return http.Response(
          json.encode({
            'meals': [
              {
                'idMeal': '500',
                'strMeal': 'Garlic Butter Pasta',
                'strMealThumb': '',
                'strCategory': 'Pasta',
              },
            ],
          }),
          200,
        );
      });
      final recipeService = RecipeService(client: mockClient);

      final pantryItems = [
        FoodItem(
          id: 'b1',
          name: 'Milk',
          category: 'Dairy',
          storageLocation: 'Fridge',
          quantity: 1,
          expiryDate: now.add(const Duration(days: 4)),
        ),
        FoodItem(
          id: 'b2',
          name: '  milk  ',
          category: 'Dairy',
          storageLocation: 'Freezer',
          quantity: 2,
          expiryDate: now.add(const Duration(days: 15)),
        ),
        FoodItem(
          id: 'b3',
          name: 'Expired Bread',
          category: 'Bakery',
          storageLocation: 'Pantry',
          quantity: 1,
          expiryDate: now.subtract(const Duration(days: 1)),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: RecipeScreen(
            userId: 'uid_test',
            itemsStream: Stream.value(pantryItems),
            recipeService: recipeService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Only one unique Milk chip appears; Expired Bread is excluded.
      expect(find.widgetWithText(FilterChip, 'Milk'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'Expired Bread'), findsNothing);
      expect(find.text('Garlic Butter Pasta'), findsOneWidget);
    });
  });
}
