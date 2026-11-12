import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/food_item.dart';
import '../models/shopping_item.dart';
import '../models/waste_log.dart';
import '../utils/price_formatter.dart';
import 'pantry_store.dart';

class ShoppingAddResult {
  final ShoppingItem item;
  final bool merged;

  const ShoppingAddResult({
    required this.item,
    required this.merged,
  });
}

class RestockResult {
  final int restockedCount;
  final int mergedPantryCount;
  final int createdPantryCount;

  const RestockResult({
    required this.restockedCount,
    required this.mergedPantryCount,
    required this.createdPantryCount,
  });

  RestockResult combineWith(RestockResult other) {
    return RestockResult(
      restockedCount: restockedCount + other.restockedCount,
      mergedPantryCount: mergedPantryCount + other.mergedPantryCount,
      createdPantryCount: createdPantryCount + other.createdPantryCount,
    );
  }
}

class PartialRestockException implements Exception {
  final RestockResult completedResult;
  final List<String> completedShoppingIds;
  final List<RestockEntry> remainingEntries;
  final Object cause;

  const PartialRestockException({
    required this.completedResult,
    required this.completedShoppingIds,
    required this.remainingEntries,
    required this.cause,
  });

  int get completedCount => completedResult.restockedCount;
  int get remainingCount => remainingEntries.length;

  @override
  String toString() {
    if (completedCount > 0) {
      return 'Moved $completedCount item(s) to Pantry, but '
          '$remainingCount remaining item(s) could not be restocked: $cause';
    }
    return '${completedShoppingIds.length} item(s) were already removed from '
        'Shopping List, while $remainingCount remaining item(s) failed: $cause';
  }
}

class _RestockChunkOutcome {
  final int restockedCount;
  final Set<String> createdIds;
  final Set<String> mergedIds;
  final List<String> completedShoppingIds;
  final Map<String, FoodItem> dirtyPantryDocs;

  const _RestockChunkOutcome({
    required this.restockedCount,
    required this.createdIds,
    required this.mergedIds,
    required this.completedShoppingIds,
    required this.dirtyPantryDocs,
  });
}

class ShoppingService {
  /// Maximum shopping entries restocked in a single Firestore transaction chunk.
  /// Worst case per entry uses 5 operations (1 shopping read + up to 2 pantry
  /// reads for canonical/legacy docs + 1 pantry set + 1 shopping delete = 2 writes).
  /// At 75 entries per chunk, a transaction executes at most 375 total ops and
  /// 150 writes, safely below Firestore's 500-write / 500-op limits.
  static const int maxTransactionRestockItems = 75;

  /// Safe per-batch delete limit (< 500 Firestore batch cap).
  static const int maxBatchDeleteOps = 400;

  final String? userId;
  final PantryStore? _storeOverride;

  ShoppingService({this.userId, PantryStore? store}) : _storeOverride = store;

  PantryStore get _store => _storeOverride ?? FirestorePantryStore();

  String _requireUid() {
    final uid = userId ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      throw StateError('No user logged in');
    }
    return uid;
  }

  CollectionReference<Map<String, dynamic>> get _shoppingList {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(_requireUid())
        .collection('shopping_list');
  }

  /// Streams the current user's shopping list, ordered unchecked-first and
  /// most-recently-updated first (sorted in Dart to avoid composite index requirements).
  Stream<List<ShoppingItem>> streamItems() {
    return _shoppingList.snapshots().map((snap) {
      final list = snap.docs.map(ShoppingItem.fromDoc).toList();
      list.sort(compareShoppingItems);
      return list;
    });
  }

  static int compareShoppingItems(ShoppingItem a, ShoppingItem b) {
    if (a.isChecked != b.isChecked) {
      return a.isChecked ? 1 : -1;
    }
    final byUpdated = b.updatedAt.compareTo(a.updatedAt);
    if (byUpdated != 0) return byUpdated;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  /// Splits [items] into bounded chunks of size <= [chunkSize] so Firestore
  /// WriteBatch commits never exceed the 500-operation limit.
  static List<List<T>> chunkList<T>(List<T> items, int chunkSize) {
    if (chunkSize < 1) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'Must be at least 1.');
    }
    if (items.isEmpty) return const [];
    final chunks = <List<T>>[];
    for (var i = 0; i < items.length; i += chunkSize) {
      final end = (i + chunkSize < items.length) ? i + chunkSize : items.length;
      chunks.add(items.sublist(i, end));
    }
    return chunks;
  }

  /// Derives Buy Again suggestions directly from existing [WasteLog] records,
  /// deduplicated by normalized food name and excluding items already queued
  /// on [shoppingItems]. Enriches default storage location from [pantryItems].
  static List<BuyAgainSuggestion> buildBuyAgainSuggestions({
    required List<WasteLog> logs,
    required List<FoodItem> pantryItems,
    required List<ShoppingItem> shoppingItems,
    int limit = 15,
  }) {
    if (logs.isEmpty || limit < 1) return const [];

    final queuedNames = <String>{
      for (final s in shoppingItems)
        if (s.normalizedName.isNotEmpty) s.normalizedName,
    };

    final pantryByName = <String, FoodItem>{};
    for (final pantryItem in pantryItems) {
      final norm = ShoppingItem.normalizeName(pantryItem.name);
      if (norm.isNotEmpty) {
        pantryByName.putIfAbsent(norm, () => pantryItem);
      }
    }

    final sortedLogs = List<WasteLog>.from(logs)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    final seenNames = <String>{};
    final suggestions = <BuyAgainSuggestion>[];

    for (final log in sortedLogs) {
      final displayName = ShoppingItem.cleanDisplayName(log.foodName);
      final normalized = ShoppingItem.normalizeName(displayName);
      if (normalized.isEmpty) continue;
      if (seenNames.contains(normalized)) continue;
      seenNames.add(normalized);

      if (queuedNames.contains(normalized)) continue;

      final matchingPantry = pantryByName[normalized];
      final storageLocation = matchingPantry != null
          ? FoodItem.normalizeStorageLocation(matchingPantry.storageLocation)
          : FoodItem.defaultStorageLocation;

      suggestions.add(
        BuyAgainSuggestion(
          name: displayName,
          normalizedName: normalized,
          category: FoodItem.normalizeCategory(log.category),
          storageLocation: storageLocation,
          lastAction: log.action,
          lastActionAt: log.timestamp,
        ),
      );

      if (suggestions.length >= limit) break;
    }

    return suggestions;
  }

  static bool isSameCalendarDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  static DateTime normalizeDateOnly(DateTime date) {
    return DateTime(date.year, date.month, date.day);
  }

  /// Ensures all restock entries carry valid quantities, storage locations,
  /// optional prices, and non-past explicit expiry dates. Deduplicates duplicate
  /// shopping item IDs in the submission list.
  static List<RestockEntry> validateRestockEntries(
    List<RestockEntry> entries, {
    DateTime? referenceNow,
  }) {
    if (entries.isEmpty) {
      throw ArgumentError('Select at least one shopping item to restock.');
    }

    final now = referenceNow ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final seenIds = <String>{};
    final validated = <RestockEntry>[];

    for (final entry in entries) {
      final id = entry.shoppingItem.id;
      if (id.isEmpty) {
        throw ArgumentError('Cannot restock a shopping item without an ID.');
      }
      if (!seenIds.add(id)) {
        // Prevent accidental duplicate processing in the same submission.
        continue;
      }
      if (entry.quantity < 1) {
        throw ArgumentError.value(
          entry.quantity,
          'quantity',
          'Restock quantity for "${entry.resolvedName}" must be at least 1.',
        );
      }

      final normalizedExpiry = normalizeDateOnly(entry.expiryDate);
      if (normalizedExpiry.isBefore(today)) {
        throw ArgumentError(
          'Expiry date for "${entry.resolvedName}" cannot be in the past.',
        );
      }

      final normalizedPrice = normalizeOptionalPrice(entry.totalPrice);
      if (entry.totalPrice != null &&
          entry.totalPrice! > 0 &&
          normalizedPrice == null) {
        throw ArgumentError('Invalid price for "${entry.resolvedName}".');
      }

      validated.add(
        RestockEntry(
          shoppingItem: entry.shoppingItem,
          name: entry.resolvedName,
          category: entry.resolvedCategory,
          quantity: entry.quantity,
          storageLocation:
              FoodItem.normalizeStorageLocation(entry.storageLocation),
          expiryDate: normalizedExpiry,
          totalPrice: normalizedPrice,
        ),
      );
    }

    return validated;
  }

  /// Finds an active pantry document whose identity matches [entry] closely
  /// enough to merge without distorting pricing history or storage batches:
  /// same normalized name, category, storage location, expiry calendar day,
  /// AND matching price-tracking state (both priced or both unpriced).
  static FoodItem? findMatchingPantryItem({
    required List<FoodItem> pantryItems,
    required RestockEntry entry,
  }) {
    final targetName = ShoppingItem.normalizeName(entry.resolvedName);
    final targetCategory = entry.resolvedCategory;
    final targetLocation =
        FoodItem.normalizeStorageLocation(entry.storageLocation);
    final targetHasPrice = normalizeOptionalPrice(entry.totalPrice) != null;

    for (final existing in pantryItems) {
      if (ShoppingItem.normalizeName(existing.name) != targetName) continue;
      if (FoodItem.normalizeCategory(existing.category) != targetCategory) {
        continue;
      }
      if (FoodItem.normalizeStorageLocation(existing.storageLocation) !=
          targetLocation) {
        continue;
      }
      if (!isSameCalendarDay(existing.expiryDate, entry.expiryDate)) continue;
      if ((existing.totalPrice != null) != targetHasPrice) continue;
      return existing;
    }
    return null;
  }

  /// Computes the merged [FoodItem] state when restocking [entry] into an
  /// exact-matching active pantry entry [existing]. Resets `originalQuantity`
  /// to the new combined stock and preserves historical logs untouched.
  static FoodItem buildMergedPantryItem({
    required FoodItem existing,
    required RestockEntry entry,
  }) {
    return FoodItem.buildMergedItem(
      existing: existing,
      fallbackName: entry.resolvedName,
      category: entry.resolvedCategory,
      storageLocation: entry.storageLocation,
      addedQuantity: entry.quantity,
      addedValue: entry.totalPrice,
      expiryDate: entry.expiryDate,
    );
  }

  /// Builds a new [ShoppingItem] state for either insert or duplicate-merge.
  static ShoppingAddResult planAddOrMerge({
    ShoppingItem? existing,
    required String id,
    required String name,
    required String category,
    required String storageLocation,
    required int quantity,
    required String source,
    DateTime? now,
  }) {
    final cleanedName = ShoppingItem.cleanDisplayName(name);
    if (cleanedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Item name cannot be empty.');
    }
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', 'Quantity must be >= 1.');
    }

    final timestamp = now ?? DateTime.now();
    final normalizedCategory = FoodItem.normalizeCategory(category);
    final normalizedLocation =
        FoodItem.normalizeStorageLocation(storageLocation);

    if (existing == null) {
      final created = ShoppingItem(
        id: id,
        name: cleanedName,
        category: normalizedCategory,
        storageLocation: normalizedLocation,
        quantity: quantity,
        isChecked: false,
        source: source,
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      return ShoppingAddResult(item: created, merged: false);
    }

    final resolvedStorageLocation = source == ShoppingItem.sourceBuyAgain
        ? existing.storageLocation
        : normalizedLocation;

    final merged = existing.copyWith(
      id: id,
      name: existing.name.isNotEmpty ? existing.name : cleanedName,
      category: normalizedCategory == 'Other' && existing.category != 'Other'
          ? existing.category
          : normalizedCategory,
      storageLocation: resolvedStorageLocation,
      quantity: existing.quantity + quantity,
      isChecked: false,
      source: source,
      updatedAt: timestamp,
    );
    return ShoppingAddResult(item: merged, merged: true);
  }

  /// Adds [name] to `users/{uid}/shopping_list`, or merges into the existing
  /// entry sharing the same normalized name inside a transaction so duplicates
  /// are prevented even under concurrent taps.
  Future<ShoppingAddResult> addOrMergeItem({
    required String name,
    String category = 'Other',
    String storageLocation = FoodItem.defaultStorageLocation,
    int quantity = 1,
    String source = ShoppingItem.sourceManual,
  }) async {
    final cleaned = ShoppingItem.cleanDisplayName(name);
    if (cleaned.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Item name cannot be empty.');
    }
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', 'Quantity must be >= 1.');
    }

    final normalized = ShoppingItem.normalizeName(cleaned);
    final deterministicId = ShoppingItem.docIdForName(cleaned);
    final col = _shoppingList;
    final deterministicRef = col.doc(deterministicId);

    // Fallback check for any legacy document created without deterministic ID.
    final legacyMatches =
        await col.where('normalizedName', isEqualTo: normalized).limit(1).get();
    final targetRef =
        legacyMatches.docs.isNotEmpty ? legacyMatches.docs.first.reference : deterministicRef;

    final db = FirebaseFirestore.instance;
    return db.runTransaction<ShoppingAddResult>((transaction) async {
      final snap = await transaction.get(targetRef);
      final existing = snap.exists ? ShoppingItem.fromDoc(snap) : null;
      final planned = planAddOrMerge(
        existing: existing,
        id: targetRef.id,
        name: cleaned,
        category: category,
        storageLocation: storageLocation,
        quantity: quantity,
        source: source,
      );

      transaction.set(targetRef, planned.item.toMap());
      return planned;
    });
  }

  /// Updates an existing shopping list item safely. If renamed to a name
  /// already present on another entry, merges quantities and removes the old doc
  /// atomically inside a transaction.
  Future<ShoppingAddResult> updateItem({
    required ShoppingItem original,
    required String name,
    required String category,
    required String storageLocation,
    required int quantity,
  }) async {
    if (original.id.isEmpty) {
      throw ArgumentError('Cannot update a shopping item without an ID.');
    }
    final cleaned = ShoppingItem.cleanDisplayName(name);
    if (cleaned.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Item name cannot be empty.');
    }
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', 'Quantity must be >= 1.');
    }

    final normalized = ShoppingItem.normalizeName(cleaned);
    final col = _shoppingList;
    final originalRef = col.doc(original.id);

    if (normalized == original.normalizedName) {
      final updated = original.copyWith(
        name: cleaned,
        category: category,
        storageLocation: storageLocation,
        quantity: quantity,
        updatedAt: DateTime.now(),
      );
      await originalRef.update(updated.toMap());
      return ShoppingAddResult(item: updated, merged: false);
    }

    final deterministicId = ShoppingItem.docIdForName(cleaned);
    final deterministicRef = col.doc(deterministicId);
    final legacyMatches =
        await col.where('normalizedName', isEqualTo: normalized).limit(1).get();
    final candidateTarget =
        legacyMatches.docs.isNotEmpty ? legacyMatches.docs.first.reference : deterministicRef;

    final db = FirebaseFirestore.instance;
    return db.runTransaction<ShoppingAddResult>((transaction) async {
      final origSnap = await transaction.get(originalRef);
      final targetSnap = await transaction.get(candidateTarget);
      if (!origSnap.exists && !targetSnap.exists) {
        throw StateError('Shopping item no longer exists.');
      }

      if (candidateTarget.id != originalRef.id && targetSnap.exists) {
        final existingTarget = ShoppingItem.fromDoc(targetSnap);
        final planned = planAddOrMerge(
          existing: existingTarget,
          id: candidateTarget.id,
          name: cleaned,
          category: category,
          storageLocation: storageLocation,
          quantity: quantity,
          source: original.source,
        );
        transaction.set(candidateTarget, planned.item.toMap());
        if (origSnap.exists) {
          transaction.delete(originalRef);
        }
        return planned;
      }

      final now = DateTime.now();
      final updated = ShoppingItem(
        id: deterministicId,
        name: cleaned,
        category: category,
        storageLocation: storageLocation,
        quantity: quantity,
        isChecked: original.isChecked,
        source: original.source,
        createdAt: original.createdAt,
        updatedAt: now,
      );
      transaction.set(deterministicRef, updated.toMap());
      if (deterministicRef.id != originalRef.id && origSnap.exists) {
        transaction.delete(originalRef);
      }
      return ShoppingAddResult(item: updated, merged: false);
    });
  }

  Future<void> toggleChecked(ShoppingItem item, bool isChecked) {
    if (item.id.isEmpty) {
      throw ArgumentError('Cannot toggle an item without an ID.');
    }
    return _shoppingList.doc(item.id).update({
      'isChecked': isChecked,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    });
  }

  Future<void> updateQuantity(ShoppingItem item, int quantity) {
    if (item.id.isEmpty) {
      throw ArgumentError('Cannot update quantity without an ID.');
    }
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', 'Quantity must be >= 1.');
    }
    return _shoppingList.doc(item.id).update({
      'quantity': quantity,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    });
  }

  Future<void> deleteItem(String id) {
    if (id.isEmpty) {
      throw ArgumentError('Cannot delete an item without an ID.');
    }
    return _shoppingList.doc(id).delete();
  }

  Future<void> clearChecked(List<ShoppingItem> items) async {
    final checkedIds = items
        .where((item) => item.isChecked && item.id.isNotEmpty)
        .map((item) => item.id)
        .toList();
    if (checkedIds.isEmpty) return;

    final db = FirebaseFirestore.instance;
    final col = _shoppingList;
    for (final chunk in chunkList(checkedIds, maxBatchDeleteOps)) {
      final batch = db.batch();
      for (final id in chunk) {
        batch.delete(col.doc(id));
      }
      await batch.commit();
    }
  }

  /// Moves [entries] to Pantry and deletes the corresponding Shopping List
  /// documents using bounded Firestore transaction chunks (<= [maxTransactionRestockItems]
  /// entries per transaction, adjustable via [transactionChunkSize] down to 1).
  ///
  /// Each chunk re-reads Shopping List docs and deterministic canonical (plus any
  /// matching legacy) Pantry docs inside the transaction so duplicate restocks,
  /// retries, and concurrent Pantry additions merge or skip idempotently.
  ///
  /// Multiple chunks execute sequentially and do NOT provide global atomicity
  /// across chunks: if a later chunk fails after earlier chunks committed,
  /// [PartialRestockException] is thrown with exact committed progress and
  /// remaining un-processed entries.
  Future<RestockResult> restockItems(
    List<RestockEntry> entries, {
    int transactionChunkSize = maxTransactionRestockItems,
  }) async {
    if (transactionChunkSize < 1 ||
        transactionChunkSize > maxTransactionRestockItems) {
      throw RangeError.range(
        transactionChunkSize,
        1,
        maxTransactionRestockItems,
        'transactionChunkSize',
      );
    }

    final validated = validateRestockEntries(entries);
    if (validated.isEmpty) {
      return const RestockResult(
        restockedCount: 0,
        mergedPantryCount: 0,
        createdPantryCount: 0,
      );
    }

    final uid = _requireUid();
    final activeStore = _store;

    // Pre-fetch active Pantry items to detect any non-canonical legacy or edited docs.
    // Canonical deterministic docs are always read live inside each transaction.
    final initialPantry = await activeStore.fetchPantryItems(uid);
    final activePantryById = <String, FoodItem>{
      for (final item in initialPantry)
        if (item.id.isNotEmpty) item.id: item,
    };

    final chunks = chunkList(validated, transactionChunkSize);
    var chunksSucceeded = 0;
    var cumulativeRestocked = 0;
    final createdPantryIds = <String>{};
    final mergedPantryIds = <String>{};
    final completedShoppingIds = <String>[];

    for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
      final chunk = chunks[chunkIndex];
      try {
        final chunkOutcome =
            await activeStore.runTransaction<_RestockChunkOutcome>(
                uid, (tx) async {
          // Phase 1A: Re-read all Shopping List docs in this chunk inside tx.
          final existingShoppingIds = <String>{};
          for (final entry in chunk) {
            final shopSnap = await tx.getShoppingDoc(entry.shoppingItem.id);
            if (shopSnap.exists) {
              existingShoppingIds.add(entry.shoppingItem.id);
            }
          }

          // Phase 1B: Collect all deterministic canonical + matching legacy Pantry IDs.
          final knownPantrySnapshot = activePantryById.values.toList();
          final pantryIdsToRead = <String>{};
          final entryCanonicalIds = <String, String>{};
          final entryLegacyIds = <String, String?>{};

          for (final entry in chunk) {
            if (!existingShoppingIds.contains(entry.shoppingItem.id)) continue;

            final canonicalId = FoodItem.batchDocId(
              name: entry.resolvedName,
              category: entry.resolvedCategory,
              storageLocation: entry.storageLocation,
              expiryDate: entry.expiryDate,
              totalPrice: entry.totalPrice,
            );
            entryCanonicalIds[entry.shoppingItem.id] = canonicalId;
            pantryIdsToRead.add(canonicalId);

            final legacyMatch = findMatchingPantryItem(
              pantryItems: knownPantrySnapshot,
              entry: entry,
            );
            final legacyId = (legacyMatch != null &&
                    legacyMatch.id.isNotEmpty &&
                    legacyMatch.id != canonicalId)
                ? legacyMatch.id
                : null;
            entryLegacyIds[entry.shoppingItem.id] = legacyId;
            if (legacyId != null) {
              pantryIdsToRead.add(legacyId);
            }
          }

          // Phase 1C: Read every candidate Pantry doc live inside transaction.
          final livePantryById = <String, FoodItem>{};
          for (final pantryId in pantryIdsToRead) {
            final snap = await tx.getPantryDoc(pantryId);
            if (snap.exists && snap.data != null) {
              livePantryById[pantryId] = FoodItem.fromMap(pantryId, snap.data!);
            }
          }

          // Phase 2: Build merged/created Pantry docs & delete Shopping List docs.
          final workingPantryList = List<FoodItem>.from(knownPantrySnapshot);
          for (final pantryId in pantryIdsToRead) {
            workingPantryList.removeWhere((item) => item.id == pantryId);
            final liveDoc = livePantryById[pantryId];
            if (liveDoc != null) {
              workingPantryList.add(liveDoc);
            }
          }

          final dirtyPantryDocs = <String, FoodItem>{};
          final createdInChunk = <String>{};
          final mergedExistingInChunk = <String>{};
          final shoppingIdsToDelete = <String>[];

          for (final entry in chunk) {
            if (!existingShoppingIds.contains(entry.shoppingItem.id)) continue;

            final canonicalId = entryCanonicalIds[entry.shoppingItem.id]!;
            final legacyId = entryLegacyIds[entry.shoppingItem.id];

            FoodItem? targetExisting = livePantryById[canonicalId];
            if (targetExisting == null && legacyId != null) {
              targetExisting = livePantryById[legacyId];
            }
            targetExisting ??= findMatchingPantryItem(
              pantryItems: workingPantryList,
              entry: entry,
            );

            if (targetExisting != null && targetExisting.id.isNotEmpty) {
              final merged = buildMergedPantryItem(
                existing: targetExisting,
                entry: entry,
              );
              livePantryById[merged.id] = merged;
              dirtyPantryDocs[merged.id] = merged;
              workingPantryList.removeWhere((item) => item.id == merged.id);
              workingPantryList.add(merged);

              if (!createdInChunk.contains(merged.id)) {
                mergedExistingInChunk.add(merged.id);
              }
            } else {
              final newFood = FoodItem.buildForSave(
                name: entry.resolvedName,
                category: entry.resolvedCategory,
                storageLocation: entry.storageLocation,
                quantity: entry.quantity,
                totalPrice: entry.totalPrice,
                expiryDate: entry.expiryDate,
              );
              final createdFood = FoodItem(
                id: canonicalId,
                name: newFood.name,
                category: newFood.category,
                storageLocation: newFood.storageLocation,
                quantity: newFood.quantity,
                originalQuantity: newFood.effectiveOriginalQuantity,
                totalPrice: newFood.totalPrice,
                expiryDate: newFood.expiryDate,
              );
              livePantryById[canonicalId] = createdFood;
              dirtyPantryDocs[canonicalId] = createdFood;
              workingPantryList.add(createdFood);
              createdInChunk.add(canonicalId);
            }

            shoppingIdsToDelete.add(entry.shoppingItem.id);
          }

          for (final pantryWrite in dirtyPantryDocs.entries) {
            tx.setPantryDoc(pantryWrite.key, pantryWrite.value.toMap());
          }
          for (final shopId in shoppingIdsToDelete) {
            tx.deleteShoppingDoc(shopId);
          }

          return _RestockChunkOutcome(
            restockedCount: shoppingIdsToDelete.length,
            createdIds: createdInChunk,
            mergedIds: mergedExistingInChunk,
            completedShoppingIds:
                chunk.map((e) => e.shoppingItem.id).toList(),
            dirtyPantryDocs: dirtyPantryDocs,
          );
        });

        chunksSucceeded++;
        cumulativeRestocked += chunkOutcome.restockedCount;
        for (final createdId in chunkOutcome.createdIds) {
          createdPantryIds.add(createdId);
          mergedPantryIds.remove(createdId);
        }
        for (final mergedId in chunkOutcome.mergedIds) {
          if (!createdPantryIds.contains(mergedId)) {
            mergedPantryIds.add(mergedId);
          }
        }
        completedShoppingIds.addAll(chunkOutcome.completedShoppingIds);
        activePantryById.addAll(chunkOutcome.dirtyPantryDocs);
      } catch (e) {
        if (chunksSucceeded == 0) {
          rethrow;
        }
        final remainingEntries = <RestockEntry>[
          for (var j = chunkIndex; j < chunks.length; j++) ...chunks[j],
        ];
        throw PartialRestockException(
          completedResult: RestockResult(
            restockedCount: cumulativeRestocked,
            mergedPantryCount: mergedPantryIds.length,
            createdPantryCount: createdPantryIds.length,
          ),
          completedShoppingIds:
              List<String>.unmodifiable(completedShoppingIds),
          remainingEntries: List<RestockEntry>.unmodifiable(remainingEntries),
          cause: e,
        );
      }
    }

    return RestockResult(
      restockedCount: cumulativeRestocked,
      mergedPantryCount: mergedPantryIds.length,
      createdPantryCount: createdPantryIds.length,
    );
  }
}
