import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:freshtrack/models/food_item.dart';
import 'package:freshtrack/models/recipe.dart';
import 'package:freshtrack/models/shopping_item.dart';
import 'package:freshtrack/models/waste_log.dart';
import 'package:freshtrack/screens/stats_screen.dart';
import 'package:freshtrack/services/food_service.dart';
import 'package:freshtrack/services/recipe_service.dart';
import 'package:freshtrack/services/shopping_service.dart';

void main() {
  group('Recipe Model Tests', () {
    test('Correctly parses full meal JSON with ingredients', () {
      final json = {
        'idMeal': '52772',
        'strMeal': 'Teriyaki Chicken Casserole',
        'strMealThumb': 'https://www.themealdb.com/images/media/meals/wvpsxx1468256321.jpg',
        'strCategory': 'Chicken',
        'strArea': 'Japanese',
        'strInstructions': 'Cook the chicken and vegetables...',
        'strIngredient1': 'Chicken',
        'strMeasure1': '3/4 cup',
        'strIngredient2': 'Soy Sauce',
        'strMeasure2': '1/2 cup',
        'strIngredient3': '',
        'strMeasure3': '',
      };

      final recipe = Recipe.fromMealJson(json);

      expect(recipe.id, '52772');
      expect(recipe.title, 'Teriyaki Chicken Casserole');
      expect(recipe.category, 'Chicken');
      expect(recipe.area, 'Japanese');
      expect(recipe.ingredients.length, 2);
      expect(recipe.ingredients.first, 'Chicken (3/4 cup)');
    });

    test('Correctly parses filter meal JSON', () {
      final json = {
        'idMeal': '52771',
        'strMeal': 'Spicy Arrabiata Penne',
        'strMealThumb': 'https://www.themealdb.com/images/media/meals/ustsqw1468250014.jpg',
      };

      final recipe = Recipe.fromFilterJson(json);

      expect(recipe.id, '52771');
      expect(recipe.title, 'Spicy Arrabiata Penne');
      expect(recipe.thumbnail, contains('themealdb'));
    });
  });

  group('WasteLog Model Tests', () {
    test('Correctly converts to Map for Firestore storage', () {
      final now = DateTime.now();
      final log = WasteLog(
        id: 'test_1',
        foodName: 'Apples',
        category: 'Fruits',
        quantity: 3,
        action: 'consumed',
        timestamp: now,
      );

      final map = log.toMap();

      expect(map['foodName'], 'Apples');
      expect(map['category'], 'Fruits');
      expect(map['quantity'], 3);
      expect(map['action'], 'consumed');
    });

    test('Safely deserializes WasteLog from sparse map', () {
      final now = DateTime(2026, 11, 10, 8, 30);
      final parsed = WasteLog.fromMap('log_1', {
        'foodName': 'Milk',
        'category': 'Dairy',
        'quantity': 2.0,
        'action': 'wasted',
        'timestamp': now,
      });

      expect(parsed.id, 'log_1');
      expect(parsed.foodName, 'Milk');
      expect(parsed.category, 'Dairy');
      expect(parsed.quantity, 2);
      expect(parsed.action, 'wasted');
      expect(parsed.timestamp, now);

      final fallback = WasteLog.fromMap('log_2', const {});
      expect(fallback.id, 'log_2');
      expect(fallback.foodName, '');
      expect(fallback.category, 'Other');
      expect(fallback.quantity, 1);
      expect(fallback.action, 'consumed');
      expect(fallback.financialValue, isNull);
    });

    test('Preserves proportional financial snapshot in WasteLog', () {
      final now = DateTime(2026, 11, 10, 12, 0);
      final pricedLog = WasteLog(
        id: 'log_3',
        foodName: 'Milk',
        category: 'Dairy',
        quantity: 1,
        action: 'wasted',
        timestamp: now,
        sourceItemId: 'item_milk',
        originalQuantity: 2,
        originalTotalPrice: 500,
        financialValue: 250,
      );

      final map = pricedLog.toMap();
      expect(map['sourceItemId'], 'item_milk');
      expect(map['originalQuantity'], 2);
      expect(map['originalTotalPrice'], 500.0);
      expect(map['financialValue'], 250.0);

      final reparsed = WasteLog.fromMap('log_3', map);
      expect(reparsed.financialValue, 250.0);
      expect(reparsed.originalQuantity, 2);
      expect(reparsed.originalTotalPrice, 500.0);
    });
  });

  group('Partial Action Transaction & Stats Summary Tests', () {
    test('buildActionTransition handles partial deduction, zero deletion, and validation', () {
      // Milk qty 4 at total Rs. 1000 (Rs. 250 each): consume 1 -> remaining 3, financialValue 250
      final step1 = FoodService.buildActionTransition(
        itemId: 'milk_doc',
        liveItemData: {
          'name': 'Milk',
          'category': 'Dairy',
          'quantity': 4,
          'originalQuantity': 4,
          'totalPrice': 1000,
        },
        logId: 'log_1',
        action: 'consumed',
        quantity: 1,
      );
      expect(step1.nextRemainingQuantity, 3);
      expect(step1.shouldDeleteItem, isFalse);
      expect(step1.shouldBackfillOriginalQuantity, isFalse);
      expect(step1.log.quantity, 1);
      expect(step1.log.financialValue, 250.0);

      // Consuming remaining 3 hits 0 -> active item must be deleted
      final step2 = FoodService.buildActionTransition(
        itemId: 'milk_doc',
        liveItemData: {
          'name': 'Milk',
          'category': 'Dairy',
          'quantity': 3,
          'originalQuantity': 4,
          'totalPrice': 1000,
        },
        logId: 'log_2',
        action: 'wasted',
        quantity: 3,
      );
      expect(step2.nextRemainingQuantity, 0);
      expect(step2.shouldDeleteItem, isTrue);
      expect(step2.log.quantity, 3);
      expect(step2.log.financialValue, 750.0);

      // Legacy item without originalQuantity or price: safely backfills originalQuantity
      final legacy = FoodService.buildActionTransition(
        itemId: 'legacy_doc',
        liveItemData: {
          'name': 'Rice',
          'category': 'Other',
          'quantity': 3,
        },
        logId: 'log_legacy',
        action: 'consumed',
        quantity: 1,
      );
      expect(legacy.nextRemainingQuantity, 2);
      expect(legacy.shouldDeleteItem, isFalse);
      expect(legacy.resolvedOriginalQuantity, 3);
      expect(legacy.shouldBackfillOriginalQuantity, isTrue);
      expect(legacy.log.financialValue, isNull);

      // Over-consumption rejected cleanly
      expect(
        () => FoodService.buildActionTransition(
          itemId: 'milk_doc',
          liveItemData: {'name': 'Milk', 'quantity': 2},
          logId: 'log_err',
          action: 'consumed',
          quantity: 3,
        ),
        throwsStateError,
      );

      // Non-positive quantity rejected
      expect(
        () => FoodService.buildActionTransition(
          itemId: 'milk_doc',
          liveItemData: {'name': 'Milk', 'quantity': 2},
          logId: 'log_err2',
          action: 'consumed',
          quantity: 0,
        ),
        throwsArgumentError,
      );
    });

    test('StatsSummary aggregates quantities and excludes unpriced entries from PKR sums', () {
      final now = DateTime(2026, 11, 10, 12, 0);
      final logs = [
        WasteLog(
          id: '1',
          foodName: 'Milk',
          category: 'Dairy',
          quantity: 1,
          action: 'consumed',
          timestamp: now,
          originalQuantity: 2,
          originalTotalPrice: 500,
          financialValue: 250,
        ),
        WasteLog(
          id: '2',
          foodName: 'Bread',
          category: 'Bakery',
          quantity: 2,
          action: 'consumed',
          timestamp: now,
        ), // unpriced: included in quantity, excluded from Rs.
        WasteLog(
          id: '3',
          foodName: 'Milk',
          category: 'Dairy',
          quantity: 1,
          action: 'wasted',
          timestamp: now,
          originalQuantity: 2,
          originalTotalPrice: 500,
          financialValue: 250,
        ),
      ];

      final summary = StatsSummary.fromLogs(logs);
      expect(summary.totalConsumed, 3);
      expect(summary.totalWasted, 1);
      expect(summary.efficiency, 75);
      expect(summary.wasteByCategory['Dairy'], 1);
      expect(summary.pricedConsumedCount, 1);
      expect(summary.pricedWastedCount, 1);
      expect(summary.unpricedLogCount, 1);
      expect(summary.estimatedConsumedValue, 250.0);
      expect(summary.wasteCost, 250.0);

      // If no priced wasted logs exist, wasteCost stays null (not 0).
      final unpricedOnlySummary = StatsSummary.fromLogs([logs[1]]);
      expect(unpricedOnlySummary.totalConsumed, 2);
      expect(unpricedOnlySummary.estimatedConsumedValue, isNull);
      expect(unpricedOnlySummary.wasteCost, isNull);
    });

    test('Expired FoodItem stays separate from wasted stats until explicit partial or full disposal', () {
      final expiredYogurt = FoodItem(
        id: 'exp_yogurt',
        name: 'Yogurt',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 3,
        originalQuantity: 3,
        totalPrice: 600,
        expiryDate: DateTime.now().subtract(const Duration(days: 2)),
      );
      expect(expiredYogurt.status, 'Expired');

      // Existing waste stats must NOT infer waste solely from expired Pantry status.
      final emptyStats = StatsSummary.fromLogs(const []);
      expect(emptyStats.totalWasted, 0);
      expect(emptyStats.totalConsumed, 0);
      expect(emptyStats.wasteCost, isNull);

      // User confirms 1 unit consumed (still edible) -> consumption stats only, 2 left.
      final consumePlan = FoodService.buildActionTransition(
        itemId: expiredYogurt.id,
        liveItemData: expiredYogurt.toMap(),
        logId: 'log_c1',
        action: 'consumed',
        quantity: 1,
      );
      expect(consumePlan.nextRemainingQuantity, 2);
      expect(consumePlan.shouldDeleteItem, isFalse);

      // User explicitly discards 1 expired unit -> creates partial waste snapshot, 1 left.
      final wastePlan = FoodService.buildActionTransition(
        itemId: expiredYogurt.id,
        liveItemData: {
          ...expiredYogurt.toMap(),
          'quantity': consumePlan.nextRemainingQuantity,
        },
        logId: 'log_w1',
        action: 'wasted',
        quantity: 1,
      );
      expect(wastePlan.nextRemainingQuantity, 1);
      expect(wastePlan.shouldDeleteItem, isFalse);
      expect(wastePlan.log.action, 'wasted');
      expect(wastePlan.log.quantity, 1);
      expect(wastePlan.log.financialValue, 200.0);

      final summary = StatsSummary.fromLogs([consumePlan.log, wastePlan.log]);
      expect(summary.totalConsumed, 1);
      expect(summary.totalWasted, 1);
      expect(summary.estimatedConsumedValue, 200.0);
      expect(summary.wasteCost, 200.0);
      expect(summary.efficiency, 50);
    });
  });

  group('Expiry Alert Schedule & Summary Tests', () {
    test('Maps all schedule day boundaries consistently without gaps or overlaps', () {
      final refNow = DateTime(2026, 11, 11, 9, 0);
      FoodItem withDays(int days) => FoodItem(
            id: 'd_$days',
            name: 'Food $days',
            category: 'Other',
            quantity: 1,
            expiryDate: DateTime(2026, 11, 11).add(Duration(days: days)),
          );

      final expected = <int, (ExpiryAlertLevel, String)>{
        10: (ExpiryAlertLevel.normal, 'Normal'),
        8: (ExpiryAlertLevel.normal, 'Normal'),
        7: (ExpiryAlertLevel.expiringSoon, 'Expiring Soon'),
        4: (ExpiryAlertLevel.expiringSoon, 'Expiring Soon'),
        3: (ExpiryAlertLevel.urgent, 'Urgent'),
        1: (ExpiryAlertLevel.urgent, 'Urgent'),
        0: (ExpiryAlertLevel.expiresToday, 'Expires Today'),
        -1: (ExpiryAlertLevel.expired, 'Expired'),
      };

      for (final entry in expected.entries) {
        final item = withDays(entry.key);
        expect(item.daysLeftAt(refNow), entry.key);
        expect(item.alertLevelAt(refNow), entry.value.$1);
        expect(item.statusAt(refNow), entry.value.$2);
      }
    });

    test('ExpirySummary counts disjoint alert categories without double-counting and combines banner counts', () {
      final refNow = DateTime(2026, 11, 11, 12, 0);
      FoodItem build(String id, int days) => FoodItem(
            id: id,
            name: id,
            category: 'Dairy',
            quantity: 1,
            expiryDate: DateTime(2026, 11, 11).add(Duration(days: days)),
          );

      // Mix of all 5 categories.
      final mixed = [
        build('n1', 10),
        build('n2', 8),
        build('s1', 7),
        build('s2', 4),
        build('u1', 3),
        build('u2', 1),
        build('t1', 0),
        build('e1', -1),
        build('e2', -5),
      ];

      final summary = ExpirySummary.fromItems(mixed, referenceNow: refNow);
      expect(summary.normalCount, 2);
      expect(summary.expiringSoonCount, 2);
      expect(summary.urgentCount, 2);
      expect(summary.expiresTodayCount, 1);
      expect(summary.expiredCount, 2);
      expect(summary.totalCount, mixed.length);
      expect(summary.hasAlerts, isTrue);
      expect(
        summary.alertBannerMessage,
        '2 expired, 1 expiring today, 2 urgent, and 2 expiring soon — review items or check recipes.',
      );

      // When both expiring-soon and expired exist, banner shows both counts.
      final soonAndExpired = ExpirySummary.fromItems(
        [build('s', 6), build('e', -2)],
        referenceNow: refNow,
      );
      expect(
        soonAndExpired.alertBannerMessage,
        '1 expired and 1 expiring soon — review items or check recipes.',
      );

      // Normal-only pantry suppresses alert banner.
      final normalOnly = ExpirySummary.fromItems(
        [build('n', 10)],
        referenceNow: refNow,
      );
      expect(normalOnly.hasAlerts, isFalse);
      expect(normalOnly.alertBannerMessage, isNull);
    });
  });

  group('RecipeService Reliability Tests', () {
    test('Encodes special characters in search query and parses valid meals', () async {
      Uri? capturedUri;
      final client = MockClient((request) async {
        capturedUri = request.url;
        return http.Response(
          json.encode({
            'meals': [
              {
                'idMeal': '101',
                'strMeal': 'Chicken & Rice',
                'strMealThumb': 'https://example.com/101.jpg',
                'strCategory': 'Chicken',
              },
            ],
          }),
          200,
        );
      });

      final service = RecipeService(client: client);
      final results = await service.searchRecipes('Chicken & Rice #1');

      expect(capturedUri, isNotNull);
      expect(capturedUri!.queryParameters['s'], 'Chicken & Rice #1');
      expect(capturedUri!.toString(), isNot(contains('#1')));
      expect(results, hasLength(1));
      expect(results.first.title, 'Chicken & Rice');
    });

    test('Handles timeouts and malformed JSON responses cleanly', () async {
      final timeoutClient = MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('{}', 200);
      });
      final timeoutService = RecipeService(
        client: timeoutClient,
        timeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        () => timeoutService.searchRecipes('pasta'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('timed out'),
        )),
      );

      final malformedClient = MockClient((_) async {
        return http.Response('{invalid json', 200);
      });
      final malformedService = RecipeService(client: malformedClient);
      await expectLater(
        () => malformedService.getRecipeDetails('52772'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('invalid recipe data'),
        )),
      );
    });

    test('getRandomRecipes fetches in parallel, deduplicates IDs, and reports total failure', () async {
      var calls = 0;
      final dupClient = MockClient((_) async {
        calls++;
        final id = calls.isEven ? '200' : '100';
        return http.Response(
          json.encode({
            'meals': [
              {
                'idMeal': id,
                'strMeal': 'Meal $id',
                'strMealThumb': 'https://example.com/$id.jpg',
              },
            ],
          }),
          200,
        );
      });

      final service = RecipeService(client: dupClient);
      final randoms = await service.getRandomRecipes(count: 6);
      expect(calls, 6);
      expect(randoms.map((r) => r.id).toList(), ['100', '200']);

      final failingClient = MockClient((_) async {
        return http.Response('Server error', 500);
      });
      final failingService = RecipeService(client: failingClient);
      await expectLater(
        () => failingService.getRandomRecipes(count: 3),
        throwsException,
      );
    });
  });

  group('ShoppingItem Model Tests', () {
    test('Normalizes names, categories, storage locations, and quantities', () {
      final item = ShoppingItem(
        id: 'id_1',
        name: '  Fresh   Milk  ',
        category: 'DAIRY',
        storageLocation: 'fridge',
        quantity: 0,
        source: 'unknown_source',
      );

      expect(item.name, 'Fresh Milk');
      expect(item.normalizedName, 'fresh milk');
      expect(item.category, 'Dairy');
      expect(item.storageLocation, 'Fridge');
      expect(item.quantity, 1);
      expect(item.source, ShoppingItem.sourceManual);
      expect(FoodItem.normalizeCategory('nonexistent'), 'Other');
    });

    test('docIdForName generates identical safe IDs for casing and whitespace variants', () {
      final a = ShoppingItem.docIdForName('Milk');
      final b = ShoppingItem.docIdForName('  milk  ');
      final c = ShoppingItem.docIdForName('Greek   Yogurt');
      final d = ShoppingItem.docIdForName('greek yogurt');

      expect(a, b);
      expect(c, d);
      expect(a, isNot(c));
      expect(() => ShoppingItem.docIdForName('   '), throwsArgumentError);

      final longId = ShoppingItem.docIdForName('a' * 1000);
      expect(longId.length, lessThan(1450));
      expect(longId.contains('/'), isFalse);
    });

    test('Deserializes sparse and complete Firestore maps and supports copyWith', () {
      final sparse = ShoppingItem.fromMap('sparse_1', const {});
      expect(sparse.id, 'sparse_1');
      expect(sparse.name, '');
      expect(sparse.category, 'Other');
      expect(sparse.storageLocation, 'Pantry');
      expect(sparse.quantity, 1);
      expect(sparse.isChecked, isFalse);
      expect(sparse.source, ShoppingItem.sourceManual);

      final created = DateTime(2026, 11, 10, 9, 0);
      final updated = DateTime(2026, 11, 10, 9, 30);
      final full = ShoppingItem(
        id: 'doc_milk',
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
        isChecked: true,
        source: ShoppingItem.sourceBuyAgain,
        createdAt: created,
        updatedAt: updated,
      );

      final reparsed = ShoppingItem.fromMap('doc_milk', full.toMap());
      expect(reparsed.name, 'Milk');
      expect(reparsed.normalizedName, 'milk');
      expect(reparsed.category, 'Dairy');
      expect(reparsed.storageLocation, 'Fridge');
      expect(reparsed.quantity, 2);
      expect(reparsed.isChecked, isTrue);
      expect(reparsed.source, ShoppingItem.sourceBuyAgain);

      final renamed = reparsed.copyWith(name: 'Whole   Milk', quantity: 3);
      expect(renamed.name, 'Whole Milk');
      expect(renamed.normalizedName, 'whole milk');
      expect(renamed.quantity, 3);
      expect(renamed.storageLocation, 'Fridge');
    });
  });

  group('ShoppingService Logic Tests', () {
    test('buildBuyAgainSuggestions deduplicates WasteLogs, excludes queued items, and enriches storage', () {
      final t1 = DateTime(2026, 11, 8, 10, 0);
      final t2 = DateTime(2026, 11, 9, 10, 0);
      final t3 = DateTime(2026, 11, 10, 10, 0);

      final logs = [
        WasteLog(
          id: 'l1',
          foodName: 'yogurt',
          category: 'Dairy',
          quantity: 1,
          action: 'wasted',
          timestamp: t1,
        ),
        WasteLog(
          id: 'l2',
          foodName: 'Milk',
          category: 'Dairy',
          quantity: 2,
          action: 'consumed',
          timestamp: t2,
        ),
        WasteLog(
          id: 'l3',
          foodName: 'Yogurt',
          category: 'Dairy',
          quantity: 3,
          action: 'consumed',
          timestamp: t3,
        ),
        WasteLog(
          id: 'l4',
          foodName: 'Bread',
          category: 'Bakery',
          quantity: 1,
          action: 'wasted',
          timestamp: t1,
        ),
        WasteLog(
          id: 'l5',
          foodName: '   ',
          category: 'Other',
          quantity: 1,
          action: 'consumed',
          timestamp: t3,
        ),
      ];

      final pantryItems = [
        FoodItem(
          id: 'p1',
          name: 'Milk',
          category: 'Dairy',
          storageLocation: 'Fridge',
          quantity: 1,
          expiryDate: DateTime(2026, 11, 18),
        ),
      ];

      // Milk is already on shopping list so it must not be suggested again.
      final shoppingItems = [
        ShoppingItem(
          id: ShoppingItem.docIdForName('milk'),
          name: 'Milk',
          category: 'Dairy',
          storageLocation: 'Fridge',
          quantity: 1,
        ),
      ];

      final suggestions = ShoppingService.buildBuyAgainSuggestions(
        logs: logs,
        pantryItems: pantryItems,
        shoppingItems: shoppingItems,
      );

      expect(suggestions.map((s) => s.name).toList(), ['Yogurt', 'Bread']);
      expect(suggestions.first.lastAction, 'consumed');
      expect(suggestions.first.storageLocation, 'Pantry');
      expect(suggestions.length, 2);

      // With empty shopping list, Milk gets Pantry's Fridge location.
      final allSuggestions = ShoppingService.buildBuyAgainSuggestions(
        logs: logs,
        pantryItems: pantryItems,
        shoppingItems: const [],
        limit: 2,
      );
      expect(allSuggestions.map((s) => s.name).toList(), ['Yogurt', 'Milk']);
      expect(allSuggestions[1].storageLocation, 'Fridge');
    });

    test('planAddOrMerge merges duplicate normalized names and unchecks checked items', () {
      final t0 = DateTime(2026, 11, 10, 9, 0);
      final t1 = DateTime(2026, 11, 10, 10, 0);
      final docId = ShoppingItem.docIdForName('Milk');

      final created = ShoppingService.planAddOrMerge(
        existing: null,
        id: docId,
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
        source: ShoppingItem.sourceManual,
        now: t0,
      );
      expect(created.merged, isFalse);
      expect(created.item.quantity, 2);
      expect(created.item.isChecked, isFalse);

      final checkedExisting = created.item.copyWith(isChecked: true);
      final merged = ShoppingService.planAddOrMerge(
        existing: checkedExisting,
        id: docId,
        name: '  milk ',
        category: 'Other',
        storageLocation: 'Fridge',
        quantity: 1,
        source: ShoppingItem.sourcePantry,
        now: t1,
      );
      expect(merged.merged, isTrue);
      expect(merged.item.name, 'Milk');
      expect(merged.item.category, 'Dairy');
      expect(merged.item.quantity, 3);
      expect(merged.item.isChecked, isFalse);
      expect(merged.item.createdAt, t0);
      expect(merged.item.updatedAt, t1);

      // Merging a Buy Again suggestion preserves existing Shopping List storage location.
      final buyAgainMerged = ShoppingService.planAddOrMerge(
        existing: checkedExisting,
        id: docId,
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Pantry',
        quantity: 1,
        source: ShoppingItem.sourceBuyAgain,
        now: t1,
      );
      expect(buyAgainMerged.merged, isTrue);
      expect(buyAgainMerged.item.storageLocation, 'Fridge');
      expect(buyAgainMerged.item.quantity, 3);
    });

    test('validateRestockEntries enforces explicit non-past expiry dates and deduplicates IDs', () {
      final today = DateTime(2026, 11, 10, 14, 30);
      final tomorrow = DateTime(2026, 11, 11, 9, 15);
      final yesterday = DateTime(2026, 11, 9, 23, 59);
      final itemA = ShoppingItem(id: 's_1', name: 'Eggs', category: 'Dairy');
      final itemB = ShoppingItem(id: 's_2', name: 'Apples', category: 'Fruits');

      expect(
        () => ShoppingService.validateRestockEntries(const [], referenceNow: today),
        throwsArgumentError,
      );

      expect(
        () => ShoppingService.validateRestockEntries(
          [
            RestockEntry(
              shoppingItem: itemA,
              quantity: 1,
              storageLocation: 'Fridge',
              expiryDate: yesterday,
            ),
          ],
          referenceNow: today,
        ),
        throwsArgumentError,
      );

      final valid = ShoppingService.validateRestockEntries(
        [
          RestockEntry(
            shoppingItem: itemA,
            quantity: 2,
            storageLocation: 'fridge',
            expiryDate: today,
            totalPrice: 400,
          ),
          // Duplicate shoppingItem ID in same submission must be ignored.
          RestockEntry(
            shoppingItem: itemA,
            quantity: 2,
            storageLocation: 'Fridge',
            expiryDate: tomorrow,
          ),
          RestockEntry(
            shoppingItem: itemB,
            quantity: 1,
            storageLocation: 'Pantry',
            expiryDate: tomorrow,
            totalPrice: 0,
          ),
        ],
        referenceNow: today,
      );

      expect(valid.length, 2);
      expect(valid[0].storageLocation, 'Fridge');
      expect(valid[0].expiryDate, DateTime(2026, 11, 10));
      expect(valid[0].totalPrice, 400.0);
      expect(valid[1].totalPrice, isNull);
    });

    test('findMatchingPantryItem & buildMergedPantryItem prevent duplicates safely', () {
      final expiry = DateTime(2026, 11, 20);
      final otherExpiry = DateTime(2026, 11, 25);
      final existingPriced = FoodItem(
        id: 'p_milk',
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 1,
        originalQuantity: 2, // leftover Rs. 250 from Rs. 500 / 2
        totalPrice: 500,
        expiryDate: expiry,
      );
      final existingUnpriced = FoodItem(
        id: 'p_bread',
        name: 'Bread',
        category: 'Bakery',
        storageLocation: 'Pantry',
        quantity: 2,
        expiryDate: expiry,
      );
      final pantry = [existingPriced, existingUnpriced];

      final samePricedEntry = RestockEntry(
        shoppingItem: ShoppingItem(id: 's_milk', name: 'milk', category: 'Dairy'),
        quantity: 2,
        storageLocation: 'Fridge',
        expiryDate: expiry,
        totalPrice: 500,
      );
      final matched = ShoppingService.findMatchingPantryItem(
        pantryItems: pantry,
        entry: samePricedEntry,
      );
      expect(matched?.id, 'p_milk');

      final merged = ShoppingService.buildMergedPantryItem(
        existing: matched!,
        entry: samePricedEntry,
      );
      expect(merged.quantity, 3);
      expect(merged.effectiveOriginalQuantity, 3);
      expect(merged.totalPrice, 750.0);
      expect(merged.estimatedUnitPrice, 250.0);

      // Unpriced Milk does NOT merge into priced Milk (avoids Rs. 0 dilution).
      final unpricedMilkEntry = RestockEntry(
        shoppingItem: ShoppingItem(id: 's_milk2', name: 'Milk', category: 'Dairy'),
        quantity: 1,
        storageLocation: 'Fridge',
        expiryDate: expiry,
        totalPrice: null,
      );
      expect(
        ShoppingService.findMatchingPantryItem(
          pantryItems: pantry,
          entry: unpricedMilkEntry,
        ),
        isNull,
      );

      // Different expiry date creates a distinct batch.
      final newDateMilk = RestockEntry(
        shoppingItem: ShoppingItem(id: 's_milk3', name: 'Milk', category: 'Dairy'),
        quantity: 1,
        storageLocation: 'Fridge',
        expiryDate: otherExpiry,
        totalPrice: 300,
      );
      expect(
        ShoppingService.findMatchingPantryItem(
          pantryItems: pantry,
          entry: newDateMilk,
        ),
        isNull,
      );

      // Unpriced Bread merges cleanly with unpriced Bread.
      final unpricedBreadEntry = RestockEntry(
        shoppingItem: ShoppingItem(id: 's_bread', name: 'bread', category: 'Bakery'),
        quantity: 1,
        storageLocation: 'Pantry',
        expiryDate: expiry,
      );
      final breadMatch = ShoppingService.findMatchingPantryItem(
        pantryItems: pantry,
        entry: unpricedBreadEntry,
      );
      expect(breadMatch?.id, 'p_bread');
      final mergedBread = ShoppingService.buildMergedPantryItem(
        existing: breadMatch!,
        entry: unpricedBreadEntry,
      );
      expect(mergedBread.quantity, 3);
      expect(mergedBread.totalPrice, isNull);
    });

    test('chunkList splits large lists cleanly below Firestore 500-op limits', () {
      expect(ShoppingService.chunkList<int>(const [], 75), isEmpty);
      final items = List<int>.generate(190, (i) => i);
      final chunks = ShoppingService.chunkList(
        items,
        ShoppingService.maxTransactionRestockItems,
      );
      expect(chunks.map((c) => c.length).toList(), [75, 75, 40]);
      expect(chunks.expand((c) => c).length, 190);

      final deleteChunks = ShoppingService.chunkList(
        List<int>.generate(900, (i) => i),
        ShoppingService.maxBatchDeleteOps,
      );
      expect(deleteChunks.map((c) => c.length).toList(), [400, 400, 100]);
    });
  });
}
