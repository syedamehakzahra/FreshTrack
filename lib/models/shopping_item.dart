import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'food_item.dart';

class ShoppingItem {
  static const String sourceManual = 'manual';
  static const String sourcePantry = 'pantry';
  static const String sourceBuyAgain = 'buy_again';

  final String id;
  final String name;
  final String normalizedName;
  final String category;
  final String storageLocation;
  final int quantity;
  final bool isChecked;
  final String source;
  final DateTime createdAt;
  final DateTime updatedAt;

  ShoppingItem({
    required this.id,
    required String name,
    String? normalizedName,
    String? category,
    String? storageLocation,
    int quantity = 1,
    this.isChecked = false,
    String? source,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : name = cleanDisplayName(name),
        normalizedName = normalizeName(normalizedName ?? name),
        category = FoodItem.normalizeCategory(category),
        storageLocation = FoodItem.normalizeStorageLocation(storageLocation),
        quantity = quantity < 1 ? 1 : quantity,
        source = _normalizeSource(source),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  static String cleanDisplayName(String raw) {
    return raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String normalizeName(String raw) {
    return cleanDisplayName(raw).toLowerCase();
  }

  /// Deterministic, Firestore-safe document ID derived from normalized name so
  /// case/whitespace variants resolve to the exact same shopping_list document.
  static String docIdForName(String rawName) {
    final normalized = normalizeName(rawName);
    if (normalized.isEmpty) {
      throw ArgumentError.value(rawName, 'rawName', 'Item name cannot be empty.');
    }
    var bytes = utf8.encode(normalized);
    // Keep doc ID well below Firestore's 1,500-byte document ID limit.
    if (bytes.length > 700) {
      bytes = bytes.sublist(0, 700);
    }
    final buffer = StringBuffer('item_');
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String _normalizeSource(String? raw) {
    switch (raw) {
      case sourcePantry:
      case sourceBuyAgain:
      case sourceManual:
        return raw!;
      default:
        return sourceManual;
    }
  }

  static DateTime _parseDate(dynamic raw, DateTime fallback) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    return fallback;
  }

  factory ShoppingItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    return ShoppingItem.fromMap(doc.id, doc.data() ?? const {});
  }

  factory ShoppingItem.fromMap(String id, Map<String, dynamic> data) {
    final now = DateTime.now();
    final name = cleanDisplayName((data['name'] as String?) ?? '');
    final rawNormalized = data['normalizedName'] as String?;
    final rawQuantity = (data['quantity'] as num?)?.toInt() ?? 1;
    final parsedCreatedAt = _parseDate(data['createdAt'], now);
    final parsedUpdatedAt = _parseDate(data['updatedAt'], parsedCreatedAt);

    return ShoppingItem(
      id: id,
      name: name,
      normalizedName: rawNormalized != null && rawNormalized.trim().isNotEmpty
          ? normalizeName(rawNormalized)
          : normalizeName(name),
      category: data['category'] as String?,
      storageLocation: data['storageLocation'] as String?,
      quantity: rawQuantity < 1 ? 1 : rawQuantity,
      isChecked: (data['isChecked'] as bool?) ?? false,
      source: data['source'] as String?,
      createdAt: parsedCreatedAt,
      updatedAt: parsedUpdatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'normalizedName': normalizedName,
      'category': category,
      'storageLocation': storageLocation,
      'quantity': quantity,
      'isChecked': isChecked,
      'source': source,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }

  ShoppingItem copyWith({
    String? id,
    String? name,
    String? category,
    String? storageLocation,
    int? quantity,
    bool? isChecked,
    String? source,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    final nextName = name ?? this.name;
    return ShoppingItem(
      id: id ?? this.id,
      name: nextName,
      normalizedName: normalizeName(nextName),
      category: category ?? this.category,
      storageLocation: storageLocation ?? this.storageLocation,
      quantity: quantity ?? this.quantity,
      isChecked: isChecked ?? this.isChecked,
      source: source ?? this.source,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class BuyAgainSuggestion {
  final String name;
  final String normalizedName;
  final String category;
  final String storageLocation;
  final String lastAction;
  final DateTime lastActionAt;

  const BuyAgainSuggestion({
    required this.name,
    required this.normalizedName,
    required this.category,
    required this.storageLocation,
    required this.lastAction,
    required this.lastActionAt,
  });
}

class RestockEntry {
  final ShoppingItem shoppingItem;
  final String? name;
  final String? category;
  final int quantity;
  final String storageLocation;
  final DateTime expiryDate;
  final double? totalPrice;

  const RestockEntry({
    required this.shoppingItem,
    this.name,
    this.category,
    required this.quantity,
    required this.storageLocation,
    required this.expiryDate,
    this.totalPrice,
  });

  String get resolvedName {
    final cleaned = ShoppingItem.cleanDisplayName(name ?? '');
    return cleaned.isNotEmpty ? cleaned : shoppingItem.name;
  }

  String get resolvedCategory =>
      FoodItem.normalizeCategory(category ?? shoppingItem.category);
}
