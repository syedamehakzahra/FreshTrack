import 'package:cloud_firestore/cloud_firestore.dart';

class WasteLog {
  final String id;
  final String foodName;
  final String category;
  final int quantity;
  final String action; // 'consumed' or 'wasted'
  final DateTime timestamp;

  WasteLog({
    required this.id,
    required this.foodName,
    required this.category,
    required this.quantity,
    required this.action,
    required this.timestamp,
  });

  factory WasteLog.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return WasteLog(
      id: doc.id,
      foodName: data['foodName'] ?? '',
      category: data['category'] ?? 'Other',
      quantity: (data['quantity'] as num?)?.toInt() ?? 1,
      action: data['action'] ?? 'consumed',
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'foodName': foodName,
      'category': category,
      'quantity': quantity,
      'action': action,
      'timestamp': Timestamp.fromDate(timestamp),
    };
  }
}
