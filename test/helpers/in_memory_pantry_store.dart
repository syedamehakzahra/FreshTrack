import 'dart:async';

import 'package:freshtrack/models/food_item.dart';
import 'package:freshtrack/models/shopping_item.dart';
import 'package:freshtrack/services/pantry_store.dart';

class _VersionedDoc {
  final int version;
  final Map<String, dynamic> data;

  const _VersionedDoc(this.version, this.data);
}

class _ConflictRetryException implements Exception {
  final String path;
  const _ConflictRetryException(this.path);
}

/// Deterministic in-memory MVCC [PantryStore] that enforces Firestore
/// transaction semantics (reads-before-writes, optimistic conflict detection
/// and retries, fault injection, and async read-phase interleaving hooks).
class InMemoryPantryStore implements PantryStore {
  final Map<String, Map<String, _VersionedDoc>> _pantryByUser = {};
  final Map<String, Map<String, _VersionedDoc>> _shoppingByUser = {};

  final int maxRetries;
  int transactionAttempts = 0;
  int successfulCommits = 0;

  /// Optional async hook executed inside [runTransaction] right before commit
  /// validation (after `action` finishes reads/writes), allowing tests to force
  /// concurrent modifications between transaction read and commit phases.
  Future<void> Function(int attempt, String uid)? onBeforeCommit;

  /// Optional async hook executed inside [fetchPantryItems] after snapshot copy
  /// to force races between pre-tx discovery and tx start.
  Future<void> Function(String uid)? onAfterFetchPantry;

  /// Optional failure predicate checked per commit attempt (1-based commit index
  /// across successful+attempted commits).
  Object? Function(int commitAttempt, int successfulCommits)? failCommitWhen;

  int _commitAttemptCounter = 0;

  InMemoryPantryStore({this.maxRetries = 5});

  Map<String, _VersionedDoc> _pantryMap(String uid) =>
      _pantryByUser.putIfAbsent(uid, () => <String, _VersionedDoc>{});

  Map<String, _VersionedDoc> _shoppingMap(String uid) =>
      _shoppingByUser.putIfAbsent(uid, () => <String, _VersionedDoc>{});

  static Map<String, dynamic> _clone(Map<String, dynamic> source) =>
      Map<String, dynamic>.from(source);

  void seedPantryItem(String uid, String docId, FoodItem item) {
    _pantryMap(uid)[docId] = _VersionedDoc(1, item.toMap());
  }

  void seedShoppingItem(String uid, ShoppingItem item) {
    _shoppingMap(uid)[item.id] = _VersionedDoc(1, item.toMap());
  }

  List<FoodItem> snapshotPantry(String uid) {
    return _pantryMap(uid)
        .entries
        .map((e) => FoodItem.fromMap(e.key, e.value.data))
        .toList();
  }

  List<ShoppingItem> snapshotShopping(String uid) {
    return _shoppingMap(uid)
        .entries
        .map((e) => ShoppingItem.fromMap(e.key, e.value.data))
        .toList();
  }

  @override
  Future<List<FoodItem>> fetchPantryItems(String uid) async {
    final result = snapshotPantry(uid);
    if (onAfterFetchPantry != null) {
      await onAfterFetchPantry!(uid);
    }
    return result;
  }

  @override
  Future<T> runTransaction<T>(
    String uid,
    Future<T> Function(PantryTransactionContext tx) action,
  ) async {
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      transactionAttempts++;
      final ctx = _InMemoryTransactionContext(
        pantryMap: _pantryMap(uid),
        shoppingMap: _shoppingMap(uid),
      );

      final result = await action(ctx);

      if (onBeforeCommit != null) {
        await onBeforeCommit!(attempt, uid);
      }

      if (ctx.hasWrites) {
        _commitAttemptCounter++;
        final injectedError =
            failCommitWhen?.call(_commitAttemptCounter, successfulCommits);
        if (injectedError != null) {
          throw injectedError;
        }
      }

      // Atomic validation & commit in synchronous Dart event turn.
      try {
        ctx.commit();
        if (ctx.hasWrites) {
          successfulCommits++;
        }
        return result;
      } on _ConflictRetryException {
        if (attempt == maxRetries) {
          rethrow;
        }
        // Retry from scratch, re-running action against updated store state.
        await Future<void>.delayed(Duration.zero);
      }
    }
    throw StateError('Transaction exceeded maxRetries ($maxRetries).');
  }
}

class _InMemoryTransactionContext implements PantryTransactionContext {
  final Map<String, _VersionedDoc> pantryMap;
  final Map<String, _VersionedDoc> shoppingMap;

  final Map<String, int> _readPantryVersions = {};
  final Map<String, int> _readShoppingVersions = {};
  final Map<String, Map<String, dynamic>> _pendingPantrySets = {};
  final Set<String> _pendingPantryDeletes = {};
  final Set<String> _pendingShoppingDeletes = {};
  bool _writeStarted = false;

  _InMemoryTransactionContext({
    required this.pantryMap,
    required this.shoppingMap,
  });

  bool get hasWrites =>
      _pendingPantrySets.isNotEmpty ||
      _pendingPantryDeletes.isNotEmpty ||
      _pendingShoppingDeletes.isNotEmpty;

  @override
  Future<PantryDocSnapshot> getPantryDoc(String docId) async {
    if (_writeStarted) {
      throw StateError(
        'Firestore transactions require all reads before writes.',
      );
    }
    final existing = pantryMap[docId];
    _readPantryVersions.putIfAbsent(docId, () => existing?.version ?? 0);
    return PantryDocSnapshot(
      id: docId,
      exists: existing != null,
      data: existing == null ? null : InMemoryPantryStore._clone(existing.data),
    );
  }

  @override
  Future<PantryDocSnapshot> getShoppingDoc(String docId) async {
    if (_writeStarted) {
      throw StateError(
        'Firestore transactions require all reads before writes.',
      );
    }
    final existing = shoppingMap[docId];
    _readShoppingVersions.putIfAbsent(docId, () => existing?.version ?? 0);
    return PantryDocSnapshot(
      id: docId,
      exists: existing != null,
      data: existing == null ? null : InMemoryPantryStore._clone(existing.data),
    );
  }

  @override
  void setPantryDoc(String docId, Map<String, dynamic> data) {
    _writeStarted = true;
    _pendingPantryDeletes.remove(docId);
    _pendingPantrySets[docId] = InMemoryPantryStore._clone(data);
  }

  @override
  void deletePantryDoc(String docId) {
    _writeStarted = true;
    _pendingPantrySets.remove(docId);
    _pendingPantryDeletes.add(docId);
  }

  @override
  void deleteShoppingDoc(String docId) {
    _writeStarted = true;
    _pendingShoppingDeletes.add(docId);
  }

  void commit() {
    for (final entry in _readPantryVersions.entries) {
      final liveVersion = pantryMap[entry.key]?.version ?? 0;
      if (liveVersion != entry.value) {
        throw _ConflictRetryException('items/${entry.key}');
      }
    }
    for (final entry in _readShoppingVersions.entries) {
      final liveVersion = shoppingMap[entry.key]?.version ?? 0;
      if (liveVersion != entry.value) {
        throw _ConflictRetryException('shopping_list/${entry.key}');
      }
    }

    for (final pantryId in _pendingPantryDeletes) {
      pantryMap.remove(pantryId);
    }
    for (final entry in _pendingPantrySets.entries) {
      final nextVersion = (pantryMap[entry.key]?.version ?? 0) + 1;
      pantryMap[entry.key] = _VersionedDoc(nextVersion, entry.value);
    }
    for (final shopId in _pendingShoppingDeletes) {
      shoppingMap.remove(shopId);
    }
  }
}
