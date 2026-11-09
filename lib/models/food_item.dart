import 'package:cloud_firestore/cloud_firestore.dart';

class FoodItem {
  final String id;
  final String name;
  final String category;
  final int quantity;
  final DateTime expiryDate;

  FoodItem({
    required this.id,
    required this.name,
    required this.category,
    required this.quantity,
    required this.expiryDate,
  });

  factory FoodItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return FoodItem(
      id: doc.id,
      name: data['name'] ?? '',
      category: data['category'] ?? 'Other',
      quantity: (data['quantity'] as num?)?.toInt() ?? 1,
      expiryDate: (data['expiryDate'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'category': category,
      'quantity': quantity,
      'expiryDate': Timestamp.fromDate(expiryDate),
    };
  }

  /// Date shown on screen, like 25/12/2026
  String get expiryText {
    final d = expiryDate.day.toString().padLeft(2, '0');
    final m = expiryDate.month.toString().padLeft(2, '0');
    return '$d/$m/${expiryDate.year}';
  }

  /// Days left until expiry (negative = already expired)
  int get daysLeft {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expiry =
    DateTime(expiryDate.year, expiryDate.month, expiryDate.day);
    return expiry.difference(today).inDays;
  }

  /// Fresh, Expiring soon, or Expired
  String get status {
    if (daysLeft < 0) return 'Expired';
    if (daysLeft <= 3) return 'Expiring soon';
    return 'Fresh';
  }

  /// Text like "5 days left" or "Expired 2 days ago"
  String get daysLeftText {
    final d = daysLeft;
    if (d < 0) {
      final ago = -d;
      return 'Expired $ago ${ago == 1 ? 'day' : 'days'} ago';
    }
    if (d == 0) return 'Expires today';
    if (d == 1) return '1 day left';
    return '$d days left';
  }
}