import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/price_formatter.dart';

class WasteLog {
  final String id;
  final String foodName;
  final String category;
  final int quantity;
  final String action; // 'consumed' or 'wasted'
  final DateTime timestamp;
  final String? sourceItemId;
  final int? originalQuantity;
  final double? originalTotalPrice;
  final double? financialValue;

  WasteLog({
    required this.id,
    required this.foodName,
    required this.category,
    required this.quantity,
    required this.action,
    required this.timestamp,
    this.sourceItemId,
    this.originalQuantity,
    double? originalTotalPrice,
    double? financialValue,
  })  : originalTotalPrice = normalizeOptionalPrice(originalTotalPrice),
        financialValue = (financialValue != null &&
                !financialValue.isNaN &&
                !financialValue.isInfinite &&
                financialValue >= 0)
            ? roundPrice(financialValue)
            : null;

  static double? calculateProportionalValue({
    required double? totalPrice,
    required int originalQuantity,
    required int actionQuantity,
  }) {
    final normalized = normalizeOptionalPrice(totalPrice);
    if (normalized == null || originalQuantity < 1 || actionQuantity < 1) {
      return null;
    }
    return roundPrice((normalized * actionQuantity) / originalQuantity);
  }

  factory WasteLog.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    return WasteLog.fromMap(doc.id, doc.data() ?? const {});
  }

  factory WasteLog.fromMap(String id, Map<String, dynamic> data) {
    final rawTimestamp = data['timestamp'];
    final parsedTimestamp = rawTimestamp is Timestamp
        ? rawTimestamp.toDate()
        : (rawTimestamp is DateTime ? rawTimestamp : DateTime.now());
    final rawQuantity = (data['quantity'] as num?)?.toInt() ?? 1;
    final parsedQuantity = rawQuantity < 1 ? 1 : rawQuantity;
    final rawOriginalQuantity = (data['originalQuantity'] as num?)?.toInt();
    final parsedOriginalQuantity =
        (rawOriginalQuantity != null && rawOriginalQuantity >= 1)
            ? rawOriginalQuantity
            : null;

    return WasteLog(
      id: id,
      foodName: (data['foodName'] as String?) ?? '',
      category: (data['category'] as String?) ?? 'Other',
      quantity: parsedQuantity,
      action: (data['action'] as String?) ?? 'consumed',
      timestamp: parsedTimestamp,
      sourceItemId: data['sourceItemId'] as String?,
      originalQuantity: parsedOriginalQuantity,
      originalTotalPrice: (data['originalTotalPrice'] as num?)?.toDouble(),
      financialValue: (data['financialValue'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'foodName': foodName,
      'category': category,
      'quantity': quantity,
      'action': action,
      'timestamp': Timestamp.fromDate(timestamp),
      if (sourceItemId != null) 'sourceItemId': sourceItemId,
      if (originalQuantity != null) 'originalQuantity': originalQuantity,
      if (originalTotalPrice != null)
        'originalTotalPrice': originalTotalPrice,
      if (financialValue != null) 'financialValue': financialValue,
    };
  }
}
