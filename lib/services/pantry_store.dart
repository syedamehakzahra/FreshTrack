import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/food_item.dart';

class PantryDocSnapshot {
  final String id;
  final bool exists;
  final Map<String, dynamic>? data;

  const PantryDocSnapshot({
    required this.id,
    required this.exists,
    this.data,
  });
}

abstract class PantryTransactionContext {
  Future<PantryDocSnapshot> getPantryDoc(String docId);
  Future<PantryDocSnapshot> getShoppingDoc(String docId);
  void setPantryDoc(String docId, Map<String, dynamic> data);
  void deletePantryDoc(String docId);
  void deleteShoppingDoc(String docId);
}

/// Minimal persistence & transaction boundary used by [FoodService] and
/// [ShoppingService] so both production Firestore and deterministic concurrency
/// tests exercise the exact same transaction protocol.
abstract class PantryStore {
  Future<List<FoodItem>> fetchPantryItems(String uid);

  Future<T> runTransaction<T>(
    String uid,
    Future<T> Function(PantryTransactionContext tx) action,
  );
}

class FirestorePantryStore implements PantryStore {
  final FirebaseFirestore _firestore;

  FirestorePantryStore({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  @override
  Future<List<FoodItem>> fetchPantryItems(String uid) async {
    final snap = await _firestore
        .collection('users')
        .doc(uid)
        .collection('items')
        .get();
    return snap.docs.map(FoodItem.fromDoc).toList();
  }

  @override
  Future<T> runTransaction<T>(
    String uid,
    Future<T> Function(PantryTransactionContext tx) action,
  ) {
    final userDoc = _firestore.collection('users').doc(uid);
    return _firestore.runTransaction<T>((transaction) {
      return action(_FirestoreTransactionContext(userDoc, transaction));
    });
  }
}

class _FirestoreTransactionContext implements PantryTransactionContext {
  final DocumentReference<Map<String, dynamic>> _userDoc;
  final Transaction _tx;

  _FirestoreTransactionContext(this._userDoc, this._tx);

  @override
  Future<PantryDocSnapshot> getPantryDoc(String docId) async {
    final snap = await _tx.get(_userDoc.collection('items').doc(docId));
    return PantryDocSnapshot(
      id: snap.id,
      exists: snap.exists,
      data: snap.data(),
    );
  }

  @override
  Future<PantryDocSnapshot> getShoppingDoc(String docId) async {
    final snap =
        await _tx.get(_userDoc.collection('shopping_list').doc(docId));
    return PantryDocSnapshot(
      id: snap.id,
      exists: snap.exists,
      data: snap.data(),
    );
  }

  @override
  void setPantryDoc(String docId, Map<String, dynamic> data) {
    _tx.set(_userDoc.collection('items').doc(docId), data);
  }

  @override
  void deletePantryDoc(String docId) {
    _tx.delete(_userDoc.collection('items').doc(docId));
  }

  @override
  void deleteShoppingDoc(String docId) {
    _tx.delete(_userDoc.collection('shopping_list').doc(docId));
  }
}
