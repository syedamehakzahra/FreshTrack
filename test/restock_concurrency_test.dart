import 'package:flutter_test/flutter_test.dart';
import 'package:freshtrack/models/food_item.dart';
import 'package:freshtrack/models/shopping_item.dart';
import 'package:freshtrack/services/food_service.dart';
import 'package:freshtrack/services/pantry_store.dart';
import 'package:freshtrack/services/shopping_service.dart';
import 'package:freshtrack/utils/hash_utils.dart';

import 'helpers/in_memory_pantry_store.dart';

class _DelegatedPantryStore implements PantryStore {
  final PantryStore inner;
  final Future<void> Function(int attempt)? onBeforeTransaction;

  int _attempts = 0;

  _DelegatedPantryStore(
    this.inner, {
    this.onBeforeTransaction,
  });

  @override
  Future<List<FoodItem>> fetchPantryItems(String uid) =>
      inner.fetchPantryItems(uid);

  @override
  Future<T> runTransaction<T>(
    String uid,
    Future<T> Function(PantryTransactionContext tx) action,
  ) {
    return inner.runTransaction<T>(uid, (tx) async {
      _attempts++;
      final result = await action(tx);
      if (onBeforeTransaction != null) {
        await onBeforeTransaction!(_attempts);
      }
      return result;
    });
  }
}

void main() {
  const uid = 'uid_test_1';

  ShoppingItem makeShop(
    String name, {
    int quantity = 1,
    String category = 'Dairy',
    String storageLocation = 'Fridge',
  }) {
    return ShoppingItem(
      id: ShoppingItem.docIdForName(name),
      name: name,
      category: category,
      storageLocation: storageLocation,
      quantity: quantity,
      isChecked: true,
    );
  }

  List<RestockEntry> makeEntries(
    InMemoryPantryStore store,
    int count, {
    DateTime? expiry,
    double? totalPriceEach = 100,
  }) {
    final futureExpiry =
        expiry ?? DateTime.now().add(const Duration(days: 7));
    final list = <RestockEntry>[];
    for (var i = 1; i <= count; i++) {
      final shop = makeShop('Item $i', quantity: 2);
      store.seedShoppingItem(uid, shop);
      list.add(
        RestockEntry(
          shoppingItem: shop,
          quantity: 2,
          storageLocation: 'Fridge',
          expiryDate: futureExpiry,
          totalPrice: totalPriceEach,
        ),
      );
    }
    return list;
  }

  group('Hash & Batch Identity Tests', () {
    test('sha256Hex matches FIPS 180-4 reference vectors', () {
      expect(
        sha256Hex(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('batchDocId merges only fully compatible Pantry attributes', () {
      final day1 = DateTime(2026, 11, 20, 8, 0);
      final day1Late = DateTime(2026, 11, 20, 23, 59);
      final day2 = DateTime(2026, 11, 21, 8, 0);

      final idBase = FoodItem.batchDocId(
        name: '  Fresh   Milk ',
        category: 'DAIRY',
        storageLocation: 'fridge',
        expiryDate: day1,
        totalPrice: 500,
      );
      final idSameBatch = FoodItem.batchDocId(
        name: 'fresh milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        expiryDate: day1Late,
        totalPrice: 250,
      );
      expect(idBase, idSameBatch);

      // Incompatible attributes MUST produce distinct document IDs.
      expect(
        FoodItem.batchDocId(
          name: 'Fresh Milk',
          category: 'Dairy',
          storageLocation: 'Fridge',
          expiryDate: day1,
          totalPrice: null, // unpriced vs priced
        ),
        isNot(idBase),
      );
      expect(
        FoodItem.batchDocId(
          name: 'Fresh Milk',
          category: 'Dairy',
          storageLocation: 'Freezer',
          expiryDate: day1,
          totalPrice: 500,
        ),
        isNot(idBase),
      );
      expect(
        FoodItem.batchDocId(
          name: 'Fresh Milk',
          category: 'Drinks',
          storageLocation: 'Fridge',
          expiryDate: day1,
          totalPrice: 500,
        ),
        isNot(idBase),
      );
      expect(
        FoodItem.batchDocId(
          name: 'Fresh Milk',
          category: 'Dairy',
          storageLocation: 'Fridge',
          expiryDate: day2,
          totalPrice: 500,
        ),
        isNot(idBase),
      );
    });
  });

  group('Restock Chunking, Idempotency & Concurrency Tests', () {
    test('1. Partial failure after the first committed chunk throws PartialRestockException', () async {
      final store = InMemoryPantryStore();
      final entries = makeEntries(store, 5, totalPriceEach: 150);

      // Chunk size 2 => chunks [2, 2, 1]. Fail on 2nd commit attempt.
      store.failCommitWhen = (attempt, succeeded) {
        if (attempt == 2) return StateError('Network dropped after chunk 1');
        return null;
      };

      final service = ShoppingService(userId: uid, store: store);

      await expectLater(
        () => service.restockItems(entries, transactionChunkSize: 2),
        throwsA(
          isA<PartialRestockException>()
              .having((e) => e.completedCount, 'completedCount', 2)
              .having((e) => e.remainingCount, 'remainingCount', 3)
              .having(
                (e) => e.completedShoppingIds,
                'completedShoppingIds',
                [entries[0].shoppingItem.id, entries[1].shoppingItem.id],
              )
              .having(
                (e) => e.remainingEntries.map((x) => x.shoppingItem.id).toList(),
                'remainingEntries',
                [
                  entries[2].shoppingItem.id,
                  entries[3].shoppingItem.id,
                  entries[4].shoppingItem.id,
                ],
              ),
        ),
      );

      // Chunk 1 committed to Pantry & deleted from Shopping List; Chunks 2 & 3 remain intact.
      final pantry = store.snapshotPantry(uid);
      final shopping = store.snapshotShopping(uid);
      expect(pantry.map((e) => e.name).toSet(), {'Item 1', 'Item 2'});
      expect(
        shopping.map((e) => e.name).toSet(),
        {'Item 3', 'Item 4', 'Item 5'},
      );
    });

    test('2. Retrying after partial success skips committed items and completes remaining without doubling', () async {
      final store = InMemoryPantryStore();
      final entries = makeEntries(store, 5, totalPriceEach: 200);

      // Simulate failure on chunk 2 during first run, then clear failure.
      store.failCommitWhen = (attempt, succeeded) {
        if (attempt == 2) return StateError('Temporary network interruption');
        return null;
      };

      final service = ShoppingService(userId: uid, store: store);
      PartialRestockException? firstFailure;
      try {
        await service.restockItems(entries, transactionChunkSize: 2);
      } on PartialRestockException catch (e) {
        firstFailure = e;
      }

      expect(firstFailure, isNotNull);
      expect(firstFailure!.completedCount, 2);

      // Restore network and intentionally replay ALL 5 original entries (worst-case retry!).
      store.failCommitWhen = null;
      final retryResult =
          await service.restockItems(entries, transactionChunkSize: 2);

      // Only the 3 remaining items were processed; chunk 1's 2 items were skipped.
      expect(retryResult.restockedCount, 3);
      expect(retryResult.createdPantryCount, 3);
      expect(retryResult.mergedPantryCount, 0);

      final pantry = store.snapshotPantry(uid);
      expect(pantry.length, 5);
      for (final item in pantry) {
        expect(item.quantity, 2);
        expect(item.effectiveOriginalQuantity, 2);
        expect(item.totalPrice, 200.0);
      }
      expect(store.snapshotShopping(uid), isEmpty);
    });

    test('3. Repeated restock requests are idempotent and do not duplicate Pantry stock', () async {
      final store = InMemoryPantryStore();
      final entries = makeEntries(store, 2, totalPriceEach: 300);
      final service = ShoppingService(userId: uid, store: store);

      final first = await service.restockItems(entries);
      expect(first.restockedCount, 2);
      expect(first.createdPantryCount, 2);

      final second = await service.restockItems(entries);
      expect(second.restockedCount, 0);
      expect(second.createdPantryCount, 0);
      expect(second.mergedPantryCount, 0);

      final pantry = store.snapshotPantry(uid);
      expect(pantry.length, 2);
      expect(pantry.every((i) => i.quantity == 2 && i.totalPrice == 300.0), isTrue);
    });

    test('4. Concurrent restock requests serialize via transaction retries without double-adding', () async {
      final store = InMemoryPantryStore();
      final entries = makeEntries(store, 2, totalPriceEach: 250);

      final fastService = ShoppingService(userId: uid, store: store);
      late Future<RestockResult> secondCall;
      final slowStore = _DelegatedPantryStore(
        store,
        onBeforeTransaction: (attempt) async {
          // On attempt 1, right after slowService reads shopping docs,
          // let fastService commit its restock first to force contention.
          if (attempt == 1) {
            await secondCall;
          }
        },
      );
      final slowService = ShoppingService(userId: uid, store: slowStore);

      final firstFuture = slowService.restockItems(entries);
      secondCall = fastService.restockItems(entries);

      final results = await Future.wait([firstFuture, secondCall]);
      final totalRestocked =
          results.fold<int>(0, (sum, r) => sum + r.restockedCount);

      expect(totalRestocked, 2);
      expect(results[0].restockedCount, 0);
      expect(results[1].restockedCount, 2);

      final pantry = store.snapshotPantry(uid);
      expect(pantry.length, 2);
      for (final item in pantry) {
        expect(item.quantity, 2);
        expect(item.originalQuantity, 2);
        expect(item.totalPrice, 250.0);
      }
      expect(store.snapshotShopping(uid), isEmpty);
    });

    test('5A. Concurrent direct Pantry addition and restocking merge cleanly when addItem commits first', () async {
      final store = InMemoryPantryStore();
      final expiry = DateTime.now().add(const Duration(days: 5));

      final shopMilk = makeShop('Milk', quantity: 1, category: 'Dairy');
      store.seedShoppingItem(uid, shopMilk);

      final directMilk = FoodItem.buildForSave(
        name: '  milk ',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
        totalPrice: 500,
        expiryDate: expiry,
      );

      final foodService = FoodService(userId: uid, store: store);
      Future<void>? addFuture;
      final contestedStore = _DelegatedPantryStore(
        store,
        onBeforeTransaction: (attempt) async {
          if (attempt == 1) {
            addFuture = foodService.addItem(directMilk);
            await addFuture;
          }
        },
      );
      final shoppingService = ShoppingService(userId: uid, store: contestedStore);

      final res = await shoppingService.restockItems([
        RestockEntry(
          shoppingItem: shopMilk,
          quantity: 1,
          storageLocation: 'Fridge',
          expiryDate: expiry,
          totalPrice: 250,
        ),
      ]);

      expect(res.restockedCount, 1);
      // Retried transaction saw directMilk on canonicalRef and merged cleanly!
      expect(res.mergedPantryCount, 1);
      expect(res.createdPantryCount, 0);

      final pantry = store.snapshotPantry(uid);
      expect(pantry.length, 1);
      expect(pantry.first.quantity, 3);
      expect(pantry.first.effectiveOriginalQuantity, 3);
      expect(pantry.first.totalPrice, 750.0);
      expect(store.snapshotShopping(uid), isEmpty);
    });

    test('5B. Concurrent direct Pantry addition and restocking merge cleanly when restock commits first', () async {
      final store = InMemoryPantryStore();
      final expiry = DateTime.now().add(const Duration(days: 5));

      final shopMilk = makeShop('Milk', quantity: 1, category: 'Dairy');
      store.seedShoppingItem(uid, shopMilk);

      final directMilk = FoodItem.buildForSave(
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
        totalPrice: 500,
        expiryDate: expiry,
      );

      final shoppingService = ShoppingService(userId: uid, store: store);
      final contestedFoodStore = _DelegatedPantryStore(
        store,
        onBeforeTransaction: (attempt) async {
          if (attempt == 1) {
            await shoppingService.restockItems([
              RestockEntry(
                shoppingItem: shopMilk,
                quantity: 1,
                storageLocation: 'Fridge',
                expiryDate: expiry,
                totalPrice: 250,
              ),
            ]);
          }
        },
      );
      final foodService = FoodService(userId: uid, store: contestedFoodStore);

      await foodService.addItem(directMilk);

      final pantry = store.snapshotPantry(uid);
      expect(pantry.length, 1);
      expect(pantry.first.quantity, 3);
      expect(pantry.first.effectiveOriginalQuantity, 3);
      expect(pantry.first.totalPrice, 750.0);
      expect(store.snapshotShopping(uid), isEmpty);
    });

    test('5C. Incompatible Pantry entries (unpriced, location, expiry, category) never merge under concurrency', () async {
      final store = InMemoryPantryStore();
      final expiryA = DateTime.now().add(const Duration(days: 5));
      final expiryB = DateTime.now().add(const Duration(days: 12));

      final shopMilk = makeShop('Milk', quantity: 1, category: 'Dairy');
      store.seedShoppingItem(uid, shopMilk);

      final foodService = FoodService(userId: uid, store: store);
      final shoppingService = ShoppingService(userId: uid, store: store);

      await Future.wait([
        // Unpriced Milk in Fridge expiryA
        foodService.addItem(
          FoodItem.buildForSave(
            name: 'Milk',
            category: 'Dairy',
            storageLocation: 'Fridge',
            quantity: 2,
            totalPrice: null,
            expiryDate: expiryA,
          ),
        ),
        // Priced Milk in Freezer expiryA
        foodService.addItem(
          FoodItem.buildForSave(
            name: 'Milk',
            category: 'Dairy',
            storageLocation: 'Freezer',
            quantity: 1,
            totalPrice: 300,
            expiryDate: expiryA,
          ),
        ),
        // Priced Milk in Fridge expiryB
        foodService.addItem(
          FoodItem.buildForSave(
            name: 'Milk',
            category: 'Dairy',
            storageLocation: 'Fridge',
            quantity: 1,
            totalPrice: 350,
            expiryDate: expiryB,
          ),
        ),
        // Priced Milk in Fridge expiryA via restock
        shoppingService.restockItems([
          RestockEntry(
            shoppingItem: shopMilk,
            quantity: 1,
            storageLocation: 'Fridge',
            expiryDate: expiryA,
            totalPrice: 250,
          ),
        ]),
      ]);

      final pantry = store.snapshotPantry(uid);
      expect(pantry.length, 4);
      final pricedPrices = pantry
          .where((p) => p.totalPrice != null)
          .map((p) => p.totalPrice!)
          .toSet();
      expect(pricedPrices, {250.0, 300.0, 350.0});
      expect(pantry.where((p) => p.totalPrice == null).single.quantity, 2);
    });

    test('6. Pantry quantity, baseline, and price remain accurate across retries & legacy docs', () async {
      final store = InMemoryPantryStore();
      final expiry = DateTime.now().add(const Duration(days: 6));

      // Seed a partially consumed legacy random-ID doc: 2 originally @ Rs. 500 -> 1 left (Rs. 250).
      store.seedPantryItem(
        uid,
        'legacy_milk_doc',
        FoodItem(
          id: 'legacy_milk_doc',
          name: 'Milk',
          category: 'Dairy',
          storageLocation: 'Fridge',
          quantity: 1,
          originalQuantity: 2,
          totalPrice: 500,
          expiryDate: expiry,
        ),
      );

      final shopMilk = makeShop('Milk', quantity: 2, category: 'Dairy');
      store.seedShoppingItem(uid, shopMilk);

      // Trigger a conflict on attempt 1 so the transaction retries before succeeding!
      final foodService = FoodService(userId: uid, store: store);
      final retryStore = _DelegatedPantryStore(
        store,
        onBeforeTransaction: (attempt) async {
          if (attempt == 1) {
            // Unrelated competing write on legacy_milk_doc by adding 1 unit Rs. 250
            // forces conflict & retry before restock applies!
            await foodService.addItem(
              FoodItem.buildForSave(
                name: 'Milk',
                category: 'Dairy',
                storageLocation: 'Fridge',
                quantity: 1,
                totalPrice: 250,
                expiryDate: expiry,
              ),
            );
          }
        },
      );
      final service = ShoppingService(userId: uid, store: retryStore);

      final res = await service.restockItems([
        RestockEntry(
          shoppingItem: shopMilk,
          quantity: 2,
          storageLocation: 'Fridge',
          expiryDate: expiry,
          totalPrice: 450,
        ),
      ]);

      expect(res.restockedCount, 1);
      expect(res.mergedPantryCount, 1);
      expect(res.createdPantryCount, 0);

      final pantry = store.snapshotPantry(uid);
      expect(pantry.length, 1);
      expect(pantry.first.id, 'legacy_milk_doc');
      // 1 (Rs. 250 remaining) + 1 (Rs. 250 added) + 2 (Rs. 450 restocked) = 4 units @ Rs. 950
      expect(pantry.first.quantity, 4);
      expect(pantry.first.effectiveOriginalQuantity, 4);
      expect(pantry.first.totalPrice, 950.0);
    });

    test('7. Shopping List entries remain intact when chunk 1 fails completely', () async {
      final store = InMemoryPantryStore();
      final entries = makeEntries(store, 3, totalPriceEach: 120);

      store.failCommitWhen = (_, _) => StateError('Offline / unavailable');
      final service = ShoppingService(userId: uid, store: store);

      await expectLater(
        () => service.restockItems(entries),
        throwsStateError,
      );

      expect(store.snapshotPantry(uid), isEmpty);
      final shopping = store.snapshotShopping(uid);
      expect(shopping.length, 3);
      expect(
        shopping.map((s) => s.name).toSet(),
        {'Item 1', 'Item 2', 'Item 3'},
      );
      expect(shopping.every((s) => s.quantity == 2 && s.isChecked), isTrue);
    });

    test('Manual Pantry addItem still permits past expiry dates', () async {
      final store = InMemoryPantryStore();
      final foodService = FoodService(userId: uid, store: store);
      final pastDate = DateTime.now().subtract(const Duration(days: 3));

      await foodService.addItem(
        FoodItem.buildForSave(
          name: 'Old Yogurt',
          category: 'Dairy',
          storageLocation: 'Fridge',
          quantity: 1,
          expiryDate: pastDate,
        ),
      );

      final pantry = store.snapshotPantry(uid);
      expect(pantry.length, 1);
      expect(pantry.first.status, 'Expired');
    });
  });

  group('FoodService Edit & Duplicate Batch Handling Tests', () {
    test('updateItem re-keys canonical ID and preserves partial baseline when qty & price unchanged', () async {
      final store = InMemoryPantryStore();
      final foodService = FoodService(userId: uid, store: store);
      final expiry = DateTime.now().add(const Duration(days: 7));

      final initialDocId = FoodItem.batchDocId(
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Pantry',
        expiryDate: expiry,
        totalPrice: 800,
      );
      // Partially consumed: 2 remaining from original 4 at Rs. 800 (remaining value Rs. 400).
      store.seedPantryItem(
        uid,
        initialDocId,
        FoodItem(
          id: initialDocId,
          name: 'Milk',
          category: 'Dairy',
          storageLocation: 'Pantry',
          quantity: 2,
          originalQuantity: 4,
          totalPrice: 800,
          expiryDate: expiry,
        ),
      );

      // Move storageLocation Pantry -> Fridge without changing qty or price.
      final edited = FoodItem.buildForSave(
        existing: FoodItem(
          id: initialDocId,
          name: 'Milk',
          category: 'Dairy',
          storageLocation: 'Pantry',
          quantity: 2,
          originalQuantity: 4,
          totalPrice: 800,
          expiryDate: expiry,
        ),
        name: '  Milk  ',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
        totalPrice: 800,
        expiryDate: expiry,
      );

      final result = await foodService.updateItem(edited);
      final expectedFridgeId = FoodItem.batchDocId(
        name: 'Milk',
        category: 'Dairy',
        storageLocation: 'Fridge',
        expiryDate: expiry,
        totalPrice: 800,
      );

      expect(result.merged, isFalse);
      expect(result.item.id, expectedFridgeId);
      expect(result.item.storageLocation, 'Fridge');
      expect(result.item.originalQuantity, 4);
      expect(result.item.estimatedUnitPrice, 200.0);

      final pantry = store.snapshotPantry(uid);
      expect(pantry.length, 1);
      expect(pantry.first.id, expectedFridgeId);
    });

    test('updateItem merges colliding active Pantry batches cleanly and avoids duplicates', () async {
      final store = InMemoryPantryStore();
      final foodService = FoodService(userId: uid, store: store);
      final expiry = DateTime.now().add(const Duration(days: 10));

      // Seed existing Milk batch in Fridge: 3 units @ Rs. 750.
      await foodService.addItem(
        FoodItem.buildForSave(
          name: 'Milk',
          category: 'Dairy',
          storageLocation: 'Fridge',
          quantity: 3,
          totalPrice: 750,
          expiryDate: expiry,
        ),
      );

      // Seed partially consumed Soy Milk in Pantry: 2 remaining of 4 @ Rs. 800 (remaining Rs. 400).
      final soyId = FoodItem.batchDocId(
        name: 'Soy Milk',
        category: 'Dairy',
        storageLocation: 'Pantry',
        expiryDate: expiry,
        totalPrice: 800,
      );
      final existingSoy = FoodItem(
        id: soyId,
        name: 'Soy Milk',
        category: 'Dairy',
        storageLocation: 'Pantry',
        quantity: 2,
        originalQuantity: 4,
        totalPrice: 800,
        expiryDate: expiry,
      );
      store.seedPantryItem(uid, soyId, existingSoy);

      // Edit Soy Milk -> Milk in Fridge (unchanged qty 2, totalPrice 800 -> remaining value Rs. 400).
      final editedToCollide = FoodItem.buildForSave(
        existing: existingSoy,
        name: '  milk ',
        category: 'Dairy',
        storageLocation: 'Fridge',
        quantity: 2,
        totalPrice: 800,
        expiryDate: expiry,
      );

      final result = await foodService.updateItem(editedToCollide);
      expect(result.merged, isTrue);
      // 3 (Rs. 750) + 2 remaining (Rs. 400) = 5 units @ Rs. 1,150.
      expect(result.item.quantity, 5);
      expect(result.item.originalQuantity, 5);
      expect(result.item.totalPrice, 1150.0);

      final pantry = store.snapshotPantry(uid);
      expect(pantry.length, 1);
      expect(pantry.first.name, 'Milk');
      expect(pantry.first.quantity, 5);
    });

    test('Enforces 500-character name limit and normalizes whitespace consistently', () async {
      final store = InMemoryPantryStore();
      final foodService = FoodService(userId: uid, store: store);
      final expiry = DateTime.now().add(const Duration(days: 5));

      expect(
        () => foodService.addItem(
          FoodItem(
            id: '',
            name: 'x' * 501,
            category: 'Other',
            storageLocation: 'Pantry',
            quantity: 1,
            expiryDate: expiry,
          ),
        ),
        throwsArgumentError,
      );

      await foodService.addItem(
        FoodItem(
          id: '',
          name: '  Whole   Wheat   Bread  ',
          category: 'Bakery',
          storageLocation: 'Pantry',
          quantity: 1,
          expiryDate: expiry,
        ),
      );
      final pantry = store.snapshotPantry(uid);
      expect(pantry.single.name, 'Whole Wheat Bread');
    });
  });
}
