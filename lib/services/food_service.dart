import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/food_item.dart';
import 'stats_service.dart';

class FoodService {
  final StatsService _statsService = StatsService();

  // Each user has their own list: users/{userId}/items
  CollectionReference<Map<String, dynamic>> get _items {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      throw StateError('No user logged in');
    }
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('items');
  }

  Stream<List<FoodItem>> streamItems() {
    return _items
        .orderBy('expiryDate')
        .snapshots()
        .map((snap) => snap.docs.map(FoodItem.fromDoc).toList());
  }

  Future<void> addItem(FoodItem item) => _items.add(item.toMap());
  
  Future<void> updateItem(FoodItem item) =>
      _items.doc(item.id).update(item.toMap());

  Future<void> deleteItem(String id) => _items.doc(id).delete();

  /// Marks an item as consumed, records it in stats, and removes from active items
  Future<void> markAsConsumed(FoodItem item) async {
    await _statsService.logAction(
      foodName: item.name,
      category: item.category,
      quantity: item.quantity,
      action: 'consumed',
    );
    await deleteItem(item.id);
  }

  /// Marks an item as wasted, records it in stats, and removes from active items
  Future<void> markAsWasted(FoodItem item) async {
    await _statsService.logAction(
      foodName: item.name,
      category: item.category,
      quantity: item.quantity,
      action: 'wasted',
    );
    await deleteItem(item.id);
  }
}
