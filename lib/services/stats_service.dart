import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/waste_log.dart';

class StatsService {
  CollectionReference<Map<String, dynamic>> get _logs {
    final uid = FirebaseAuth.instance.currentUser?.uid;
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
  }) async {
    final log = WasteLog(
      id: '',
      foodName: foodName,
      category: category,
      quantity: quantity,
      action: action,
      timestamp: DateTime.now(),
    );
    await _logs.add(log.toMap());
  }
}
