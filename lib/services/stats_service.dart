import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/food_item.dart';
import '../models/waste_log.dart';

class StatsService {
  final String? userId;

  StatsService({this.userId});

  CollectionReference<Map<String, dynamic>> get _logs {
    final uid = userId ?? FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      throw StateError('No user logged in');
    }
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('waste_logs');
  }

  /// Stream of logs sorted by newest first
  Stream<List<WasteLog>> streamLogs() {
    return _logs
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map(WasteLog.fromDoc).toList());
  }

  /// Log item when consumed or wasted
  Future<void> logAction({
    required String foodName,
    required String category,
    required int quantity,
    required String action, // 'consumed' | 'wasted'
    String? sourceItemId,
    int? originalQuantity,
    double? originalTotalPrice,
    double? financialValue,
  }) async {
    final cleanedName = FoodItem.cleanDisplayName(foodName);
    if (cleanedName.isEmpty) {
      throw ArgumentError.value(foodName, 'foodName', 'Food name cannot be empty.');
    }
    if (cleanedName.length > FoodItem.maxNameLength) {
      throw ArgumentError.value(
        foodName,
        'foodName',
        'Food name must be ${FoodItem.maxNameLength} characters or fewer.',
      );
    }
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', 'Quantity must be >= 1.');
    }
    if (action != 'consumed' && action != 'wasted') {
      throw ArgumentError.value(
        action,
        'action',
        'Action must be consumed or wasted.',
      );
    }

    final log = WasteLog(
      id: '',
      foodName: cleanedName,
      category: FoodItem.normalizeCategory(category),
      quantity: quantity,
      action: action,
      timestamp: DateTime.now(),
      sourceItemId: sourceItemId,
      originalQuantity: originalQuantity,
      originalTotalPrice: originalTotalPrice,
      financialValue: financialValue,
    );
    await _logs.add(log.toMap());
  }
}
