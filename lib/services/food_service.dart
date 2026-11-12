import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/food_item.dart';
import '../models/waste_log.dart';
import '../utils/price_formatter.dart';
import 'pantry_store.dart';

class ItemActionResult {
  final String action; // 'consumed' | 'wasted'
  final int processedQuantity;
  final int remainingQuantity;
  final bool deleted;
  final double? financialValue;

  const ItemActionResult({
    required this.action,
    required this.processedQuantity,
    required this.remainingQuantity,
    required this.deleted,
    required this.financialValue,
  });
}

class FoodUpdateResult {
  final FoodItem item;
  final bool merged;

  const FoodUpdateResult({
    required this.item,
    required this.merged,
  });
}

class ActionTransitionPlan {
  final int nextRemainingQuantity;
  final bool shouldDeleteItem;
  final int resolvedOriginalQuantity;
  final bool shouldBackfillOriginalQuantity;
  final WasteLog log;

  const ActionTransitionPlan({
    required this.nextRemainingQuantity,
    required this.shouldDeleteItem,
    required this.resolvedOriginalQuantity,
    required this.shouldBackfillOriginalQuantity,
    required this.log,
  });
}

class FoodService {
  final String? userId;
  final PantryStore? _storeOverride;

  FoodService({this.userId, PantryStore? store}) : _storeOverride = store;

  PantryStore get _store => _storeOverride ?? FirestorePantryStore();

  String _requireUid() {
    final uid = userId ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      throw StateError('No user logged in');
    }
    return uid;
  }

  // Each user has their own list: users/{userId}/items
  CollectionReference<Map<String, dynamic>> get _items {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(_requireUid())
        .collection('items');
  }

  Stream<List<FoodItem>> streamItems() {
    return _items
        .orderBy('expiryDate')
        .snapshots()
        .map((snap) => snap.docs.map(FoodItem.fromDoc).toList());
  }

  static FoodItem? findMatchingLegacyItem({
    required List<FoodItem> pantryItems,
    required String name,
    required String category,
    required String storageLocation,
    required DateTime expiryDate,
    required double? totalPrice,
    required String excludeId,
  }) {
    for (final existing in pantryItems) {
      if (existing.id.isEmpty || existing.id == excludeId) continue;
      if (FoodItem.matchesAttributes(
        candidate: existing,
        name: name,
        category: category,
        storageLocation: storageLocation,
        expiryDate: expiryDate,
        totalPrice: totalPrice,
      )) {
        return existing;
      }
    }
    return null;
  }

  /// Adds a Pantry item transactionally using a deterministic batch key so
  /// concurrent direct additions and Shopping List restocks merge safely
  /// without creating duplicate Pantry entries. Preserves incompatible entries
  /// separately and permits manual past expiry dates.
  Future<void> addItem(FoodItem item) async {
    if (item.quantity < 1) {
      throw ArgumentError.value(
        item.quantity,
        'quantity',
        'Quantity must be 1 or more.',
      );
    }
    final cleanedName = FoodItem.cleanDisplayName(item.name);
    if (cleanedName.isEmpty) {
      throw ArgumentError.value(
        item.name,
        'name',
        'Item name cannot be empty.',
      );
    }
    if (cleanedName.length > FoodItem.maxNameLength) {
      throw ArgumentError.value(
        item.name,
        'name',
        'Item name must be ${FoodItem.maxNameLength} characters or fewer.',
      );
    }

    final uid = _requireUid();
    final activeStore = _store;
    final normalizedCategory = FoodItem.normalizeCategory(item.category);
    final normalizedLocation =
        FoodItem.normalizeStorageLocation(item.storageLocation);
    final normalizedExpiry = FoodItem.normalizeDateOnly(item.expiryDate);

    final canonicalId = FoodItem.batchDocId(
      name: cleanedName,
      category: normalizedCategory,
      storageLocation: normalizedLocation,
      expiryDate: normalizedExpiry,
      totalPrice: item.totalPrice,
    );

    final preFetched = await activeStore.fetchPantryItems(uid);
    final legacyMatch = findMatchingLegacyItem(
      pantryItems: preFetched,
      name: cleanedName,
      category: normalizedCategory,
      storageLocation: normalizedLocation,
      expiryDate: normalizedExpiry,
      totalPrice: item.totalPrice,
      excludeId: canonicalId,
    );
    final legacyId = legacyMatch?.id;

    await activeStore.runTransaction<void>(uid, (tx) async {
      // Phase 1: Read canonical batch doc and any legacy matching doc inside tx.
      final canonicalSnap = await tx.getPantryDoc(canonicalId);
      final legacySnap =
          legacyId != null ? await tx.getPantryDoc(legacyId) : null;

      FoodItem? existingTarget;
      if (canonicalSnap.exists && canonicalSnap.data != null) {
        existingTarget = FoodItem.fromMap(canonicalId, canonicalSnap.data!);
      } else if (legacySnap != null &&
          legacySnap.exists &&
          legacySnap.data != null) {
        existingTarget = FoodItem.fromMap(legacyId!, legacySnap.data!);
      }

      // Phase 2: Merge into active batch or create deterministic canonical batch.
      if (existingTarget != null) {
        final merged = FoodItem.buildMergedItem(
          existing: existingTarget,
          fallbackName: cleanedName,
          category: normalizedCategory,
          storageLocation: normalizedLocation,
          addedQuantity: item.quantity,
          addedValue: item.remainingEstimatedValue,
          expiryDate: normalizedExpiry,
        );
        tx.setPantryDoc(merged.id, merged.toMap());
      } else {
        final created = FoodItem.buildForSave(
          name: cleanedName,
          category: normalizedCategory,
          storageLocation: normalizedLocation,
          quantity: item.quantity,
          totalPrice: item.totalPrice,
          expiryDate: normalizedExpiry,
        );
        tx.setPantryDoc(canonicalId, created.toMap());
      }
    });
  }

  /// Updates an active Pantry item transactionally, re-keying its document ID
  /// to match its canonical batch attributes and merging safely with any
  /// existing matching active Pantry batch to prevent duplicates.
  Future<FoodUpdateResult> updateItem(FoodItem item) async {
    if (item.id.isEmpty) {
      throw ArgumentError('Cannot update an item without a document ID.');
    }
    if (item.quantity < 1) {
      throw ArgumentError.value(
        item.quantity,
        'quantity',
        'Quantity must be 1 or more.',
      );
    }
    final cleanedName = FoodItem.cleanDisplayName(item.name);
    if (cleanedName.isEmpty) {
      throw ArgumentError.value(
        item.name,
        'name',
        'Item name cannot be empty.',
      );
    }
    if (cleanedName.length > FoodItem.maxNameLength) {
      throw ArgumentError.value(
        item.name,
        'name',
        'Item name must be ${FoodItem.maxNameLength} characters or fewer.',
      );
    }

    final uid = _requireUid();
    final activeStore = _store;
    final normalizedCategory = FoodItem.normalizeCategory(item.category);
    final normalizedLocation =
        FoodItem.normalizeStorageLocation(item.storageLocation);
    final normalizedExpiry = FoodItem.normalizeDateOnly(item.expiryDate);
    final normalizedPrice = normalizeOptionalPrice(item.totalPrice);

    final editedItem = FoodItem(
      id: item.id,
      name: cleanedName,
      category: normalizedCategory,
      storageLocation: normalizedLocation,
      quantity: item.quantity,
      originalQuantity: item.effectiveOriginalQuantity,
      totalPrice: normalizedPrice,
      expiryDate: normalizedExpiry,
    );

    final canonicalId = FoodItem.batchDocId(
      name: cleanedName,
      category: normalizedCategory,
      storageLocation: normalizedLocation,
      expiryDate: normalizedExpiry,
      totalPrice: normalizedPrice,
    );

    final preFetched = await activeStore.fetchPantryItems(uid);
    final legacyMatch = findMatchingLegacyItem(
      pantryItems: preFetched,
      name: cleanedName,
      category: normalizedCategory,
      storageLocation: normalizedLocation,
      expiryDate: normalizedExpiry,
      totalPrice: normalizedPrice,
      excludeId: item.id,
    );
    final legacyId =
        (legacyMatch != null && legacyMatch.id != canonicalId)
            ? legacyMatch.id
            : null;

    return activeStore.runTransaction<FoodUpdateResult>(uid, (tx) async {
      // Phase 1: Read original, canonical target, and any matching legacy doc inside tx.
      final origSnap = await tx.getPantryDoc(item.id);
      final canonicalSnap = (canonicalId != item.id)
          ? await tx.getPantryDoc(canonicalId)
          : origSnap;
      final legacySnap =
          legacyId != null ? await tx.getPantryDoc(legacyId) : null;

      if (!origSnap.exists || origSnap.data == null) {
        throw StateError('This item is no longer in your pantry.');
      }

      FoodItem? collidingTarget;
      if (canonicalId != item.id &&
          canonicalSnap.exists &&
          canonicalSnap.data != null) {
        collidingTarget = FoodItem.fromMap(canonicalId, canonicalSnap.data!);
      } else if (legacySnap != null &&
          legacySnap.exists &&
          legacySnap.data != null) {
        collidingTarget = FoodItem.fromMap(legacyId!, legacySnap.data!);
      }

      // Phase 2: Merge into colliding active batch or write updated canonical doc.
      if (collidingTarget != null) {
        final merged = FoodItem.buildMergedItem(
          existing: collidingTarget,
          fallbackName: cleanedName,
          category: normalizedCategory,
          storageLocation: normalizedLocation,
          addedQuantity: editedItem.quantity,
          addedValue: editedItem.remainingEstimatedValue,
          expiryDate: normalizedExpiry,
        );
        final saved = FoodItem(
          id: canonicalId,
          name: merged.name,
          category: merged.category,
          storageLocation: merged.storageLocation,
          quantity: merged.quantity,
          originalQuantity: merged.effectiveOriginalQuantity,
          totalPrice: merged.totalPrice,
          expiryDate: merged.expiryDate,
        );
        tx.setPantryDoc(canonicalId, saved.toMap());
        if (item.id != canonicalId) {
          tx.deletePantryDoc(item.id);
        }
        if (collidingTarget.id != canonicalId) {
          tx.deletePantryDoc(collidingTarget.id);
        }
        return FoodUpdateResult(item: saved, merged: true);
      }

      final saved = FoodItem(
        id: canonicalId,
        name: editedItem.name,
        category: editedItem.category,
        storageLocation: editedItem.storageLocation,
        quantity: editedItem.quantity,
        originalQuantity: editedItem.effectiveOriginalQuantity,
        totalPrice: editedItem.totalPrice,
        expiryDate: editedItem.expiryDate,
      );
      tx.setPantryDoc(canonicalId, saved.toMap());
      if (canonicalId != item.id) {
        tx.deletePantryDoc(item.id);
      }
      return FoodUpdateResult(item: saved, merged: false);
    });
  }

  Future<void> deleteItem(String id) => _items.doc(id).delete();

  static ActionTransitionPlan buildActionTransition({
    required String itemId,
    required Map<String, dynamic> liveItemData,
    required String logId,
    required String action,
    required int quantity,
    String fallbackName = '',
    String fallbackCategory = 'Other',
    DateTime? timestamp,
  }) {
    if (itemId.isEmpty) {
      throw ArgumentError('Cannot process an item without a document ID.');
    }
    if (action != 'consumed' && action != 'wasted') {
      throw ArgumentError.value(
        action,
        'action',
        'Action must be consumed or wasted.',
      );
    }
    if (quantity < 1) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        'Quantity must be at least 1.',
      );
    }

    final liveRemaining = (liveItemData['quantity'] as num?)?.toInt() ?? 0;
    if (liveRemaining < 1) {
      throw StateError('Item has invalid quantity in pantry.');
    }
    if (quantity > liveRemaining) {
      throw StateError(
        'Cannot mark $quantity unit(s) as $action; only $liveRemaining remaining.',
      );
    }

    final rawOriginal = (liveItemData['originalQuantity'] as num?)?.toInt();
    final hasValidOriginal =
        rawOriginal != null && rawOriginal >= liveRemaining;
    final resolvedOriginal = hasValidOriginal ? rawOriginal : liveRemaining;
    final totalPrice = normalizeOptionalPrice(
      (liveItemData['totalPrice'] as num?)?.toDouble(),
    );
    final financialValue = WasteLog.calculateProportionalValue(
      totalPrice: totalPrice,
      originalQuantity: resolvedOriginal,
      actionQuantity: quantity,
    );

    final nextRemaining = liveRemaining - quantity;
    final rawName = FoodItem.cleanDisplayName(
      (liveItemData['name'] as String?) ?? '',
    );
    final cleanFallbackName = FoodItem.cleanDisplayName(fallbackName);
    final resolvedFoodName = rawName.isNotEmpty
        ? rawName
        : (cleanFallbackName.isNotEmpty ? cleanFallbackName : 'Food item');
    final clippedFoodName = resolvedFoodName.length > FoodItem.maxNameLength
        ? resolvedFoodName.substring(0, FoodItem.maxNameLength)
        : resolvedFoodName;
    final rawCategory = (liveItemData['category'] as String?)?.trim();
    final cleanFallbackCategory = fallbackCategory.trim();
    final resolvedCategory = (rawCategory != null && rawCategory.isNotEmpty)
        ? rawCategory
        : (cleanFallbackCategory.isNotEmpty ? cleanFallbackCategory : 'Other');

    final log = WasteLog(
      id: logId,
      foodName: clippedFoodName,
      category: resolvedCategory,
      quantity: quantity,
      action: action,
      timestamp: timestamp ?? DateTime.now(),
      sourceItemId: itemId,
      originalQuantity: resolvedOriginal,
      originalTotalPrice: totalPrice,
      financialValue: financialValue,
    );

    return ActionTransitionPlan(
      nextRemainingQuantity: nextRemaining,
      shouldDeleteItem: nextRemaining == 0,
      resolvedOriginalQuantity: resolvedOriginal,
      shouldBackfillOriginalQuantity: !hasValidOriginal,
      log: log,
    );
  }

  /// Atomically logs a partial or full consume/waste event and updates or deletes
  /// the active pantry item inside a server-authoritative Firestore transaction.
  Future<ItemActionResult> processItemAction(
    FoodItem item, {
    required String action,
    required int quantity,
  }) async {
    if (item.id.isEmpty) {
      throw ArgumentError('Cannot process an item without a document ID.');
    }
    if (action != 'consumed' && action != 'wasted') {
      throw ArgumentError.value(
        action,
        'action',
        'Action must be consumed or wasted.',
      );
    }
    if (quantity < 1) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        'Quantity must be at least 1.',
      );
    }

    final db = FirebaseFirestore.instance;
    final userDoc = db.collection('users').doc(_requireUid());
    final itemRef = userDoc.collection('items').doc(item.id);
    final logRef = userDoc.collection('waste_logs').doc();

    return db.runTransaction<ItemActionResult>((transaction) async {
      final snapshot = await transaction.get(itemRef);
      if (!snapshot.exists) {
        throw StateError('This item is no longer in your pantry.');
      }

      final liveData = snapshot.data() ?? const <String, dynamic>{};
      final plan = buildActionTransition(
        itemId: item.id,
        liveItemData: liveData,
        logId: logRef.id,
        action: action,
        quantity: quantity,
        fallbackName: item.name,
        fallbackCategory: item.category,
      );

      transaction.set(logRef, plan.log.toMap());
      if (plan.shouldDeleteItem) {
        transaction.delete(itemRef);
      } else {
        transaction.update(itemRef, {
          'quantity': plan.nextRemainingQuantity,
          if (plan.shouldBackfillOriginalQuantity)
            'originalQuantity': plan.resolvedOriginalQuantity,
        });
      }

      return ItemActionResult(
        action: action,
        processedQuantity: quantity,
        remainingQuantity: plan.nextRemainingQuantity,
        deleted: plan.shouldDeleteItem,
        financialValue: plan.log.financialValue,
      );
    });
  }

  /// Marks [quantity] (defaulting to full remaining stock) as consumed and logs it.
  Future<ItemActionResult> markAsConsumed(FoodItem item, {int? quantity}) =>
      processItemAction(
        item,
        action: 'consumed',
        quantity: quantity ?? item.quantity,
      );

  /// Marks [quantity] (defaulting to full remaining stock) as wasted and logs it.
  Future<ItemActionResult> markAsWasted(FoodItem item, {int? quantity}) =>
      processItemAction(
        item,
        action: 'wasted',
        quantity: quantity ?? item.quantity,
      );
}
