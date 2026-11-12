import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/hash_utils.dart';
import '../utils/price_formatter.dart';

enum ExpiryAlertLevel {
  normal,
  expiringSoon,
  urgent,
  expiresToday,
  expired,
}

class FoodItem {
  static const List<String> categories = [
    'Dairy',
    'Meat',
    'Vegetables',
    'Fruits',
    'Bakery',
    'Drinks',
    'Frozen',
    'Other',
  ];

  static const List<String> storageLocations = [
    'Fridge',
    'Freezer',
    'Pantry',
  ];

  static const String defaultStorageLocation = 'Pantry';
  static const int maxNameLength = 500;

  static String cleanDisplayName(String raw) {
    return raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  final String id;
  final String name;
  final String category;
  final String storageLocation;
  final int quantity;
  final int? originalQuantity;
  final double? totalPrice;
  final DateTime expiryDate;

  FoodItem({
    required this.id,
    required this.name,
    required this.category,
    this.storageLocation = defaultStorageLocation,
    required this.quantity,
    this.originalQuantity,
    double? totalPrice,
    required this.expiryDate,
  }) : totalPrice = normalizeOptionalPrice(totalPrice);

  int get effectiveOriginalQuantity {
    final safeRemaining = quantity >= 1 ? quantity : 1;
    if (originalQuantity != null && originalQuantity! >= safeRemaining) {
      return originalQuantity!;
    }
    return safeRemaining;
  }

  bool get isPartiallyConsumed => quantity < effectiveOriginalQuantity;

  double? get estimatedUnitPrice {
    if (totalPrice == null || effectiveOriginalQuantity < 1) return null;
    return roundPrice(totalPrice! / effectiveOriginalQuantity);
  }

  double? proportionalValueFor(int actionQuantity) {
    if (totalPrice == null ||
        actionQuantity < 1 ||
        effectiveOriginalQuantity < 1) {
      return null;
    }
    return roundPrice((totalPrice! * actionQuantity) / effectiveOriginalQuantity);
  }

  double? get remainingEstimatedValue => proportionalValueFor(quantity);

  static FoodItem buildForSave({
    FoodItem? existing,
    required String name,
    required String category,
    required String storageLocation,
    required int quantity,
    double? totalPrice,
    required DateTime expiryDate,
  }) {
    if (quantity < 1) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        'Quantity must be at least 1.',
      );
    }
    final normalizedPrice = normalizeOptionalPrice(totalPrice);
    final int resolvedOriginalQuantity;
    if (existing == null) {
      resolvedOriginalQuantity = quantity;
    } else {
      final quantityChanged = quantity != existing.quantity;
      final priceChanged =
          !optionalPricesEqual(normalizedPrice, existing.totalPrice);
      resolvedOriginalQuantity = (!quantityChanged && !priceChanged)
          ? existing.effectiveOriginalQuantity
          : quantity;
    }

    final cleanedName = cleanDisplayName(name);
    if (cleanedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Item name cannot be empty.');
    }
    if (cleanedName.length > maxNameLength) {
      throw ArgumentError.value(
        name,
        'name',
        'Item name must be $maxNameLength characters or fewer.',
      );
    }

    return FoodItem(
      id: existing?.id ?? '',
      name: cleanedName,
      category: normalizeCategory(category),
      storageLocation: normalizeStorageLocation(storageLocation),
      quantity: quantity,
      originalQuantity: resolvedOriginalQuantity,
      totalPrice: normalizedPrice,
      expiryDate: normalizeDateOnly(expiryDate),
    );
  }

  static String normalizeName(String raw) {
    return cleanDisplayName(raw).toLowerCase();
  }

  static DateTime _utcCalendarDate(DateTime date) {
    final local = date.isUtc ? date.toLocal() : date;
    return DateTime.utc(local.year, local.month, local.day);
  }

  static DateTime normalizeDateOnly(DateTime date) {
    final local = date.isUtc ? date.toLocal() : date;
    return DateTime(local.year, local.month, local.day);
  }

  static bool isSameCalendarDay(DateTime a, DateTime b) {
    final na = normalizeDateOnly(a);
    final nb = normalizeDateOnly(b);
    return na.year == nb.year && na.month == nb.month && na.day == nb.day;
  }

  static String expiryDayKey(DateTime date) {
    final normalized = normalizeDateOnly(date);
    final y = normalized.year.toString().padLeft(4, '0');
    final m = normalized.month.toString().padLeft(2, '0');
    final d = normalized.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String batchKey({
    required String name,
    required String category,
    required String storageLocation,
    required DateTime expiryDate,
    required double? totalPrice,
  }) {
    final normName = normalizeName(name);
    if (normName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Item name cannot be empty.');
    }
    final normCategory = normalizeCategory(category);
    final normLocation = normalizeStorageLocation(storageLocation);
    final dayKey = expiryDayKey(expiryDate);
    final priceMode =
        normalizeOptionalPrice(totalPrice) != null ? 'priced' : 'unpriced';
    return '$normName\x00$normCategory\x00$normLocation\x00$dayKey\x00$priceMode';
  }

  /// Deterministic Firestore-safe document ID representing an active Pantry
  /// batch keyed by normalized name, category, storage location, calendar-day
  /// expiry date, and priced/unpriced state.
  static String batchDocId({
    required String name,
    required String category,
    required String storageLocation,
    required DateTime expiryDate,
    required double? totalPrice,
  }) {
    final key = batchKey(
      name: name,
      category: category,
      storageLocation: storageLocation,
      expiryDate: expiryDate,
      totalPrice: totalPrice,
    );
    return 'batch_${sha256Hex(key)}';
  }

  static bool matchesAttributes({
    required FoodItem candidate,
    required String name,
    required String category,
    required String storageLocation,
    required DateTime expiryDate,
    required double? totalPrice,
  }) {
    if (normalizeName(candidate.name) != normalizeName(name)) return false;
    if (normalizeCategory(candidate.category) != normalizeCategory(category)) {
      return false;
    }
    if (normalizeStorageLocation(candidate.storageLocation) !=
        normalizeStorageLocation(storageLocation)) {
      return false;
    }
    if (!isSameCalendarDay(candidate.expiryDate, expiryDate)) return false;
    final candidateHasPrice = candidate.totalPrice != null;
    final targetHasPrice = normalizeOptionalPrice(totalPrice) != null;
    return candidateHasPrice == targetHasPrice;
  }

  /// Merges [addedQuantity] (and optional [addedValue]) into an exact-matching
  /// active Pantry [existing] entry, resetting `originalQuantity` to the new
  /// combined stock while leaving historical `WasteLog`s untouched.
  static FoodItem buildMergedItem({
    required FoodItem existing,
    required String fallbackName,
    required String category,
    required String storageLocation,
    required int addedQuantity,
    required double? addedValue,
    required DateTime expiryDate,
  }) {
    if (addedQuantity < 1) {
      throw ArgumentError.value(
        addedQuantity,
        'addedQuantity',
        'Added quantity must be at least 1.',
      );
    }

    final mergedQuantity = existing.quantity + addedQuantity;
    final normalizedAddedValue = normalizeOptionalPrice(addedValue);
    final existingRemainingValue = existing.remainingEstimatedValue;

    final double? mergedTotalPrice;
    if (existingRemainingValue != null && normalizedAddedValue != null) {
      mergedTotalPrice = roundPrice(existingRemainingValue + normalizedAddedValue);
    } else if (existingRemainingValue == null && normalizedAddedValue == null) {
      mergedTotalPrice = null;
    } else {
      throw StateError(
        'Cannot merge priced and unpriced pantry entries without distorting averages.',
      );
    }

    final cleanedFallback = cleanDisplayName(fallbackName);
    final cleanedExisting = cleanDisplayName(existing.name);
    return FoodItem(
      id: existing.id,
      name: cleanedExisting.isNotEmpty ? cleanedExisting : cleanedFallback,
      category: normalizeCategory(category),
      storageLocation: normalizeStorageLocation(storageLocation),
      quantity: mergedQuantity,
      originalQuantity: mergedQuantity,
      totalPrice: mergedTotalPrice,
      expiryDate: normalizeDateOnly(expiryDate),
    );
  }

  static String normalizeCategory(dynamic raw) {
    if (raw is String) {
      final normalized = raw.trim().toLowerCase();
      for (final option in categories) {
        if (option.toLowerCase() == normalized) {
          return option;
        }
      }
    }
    return 'Other';
  }

  static String normalizeStorageLocation(dynamic raw) {
    if (raw is String) {
      final normalized = raw.trim().toLowerCase();
      for (final option in storageLocations) {
        if (option.toLowerCase() == normalized) {
          return option;
        }
      }
    }
    return defaultStorageLocation;
  }

  factory FoodItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    return FoodItem.fromMap(doc.id, doc.data() ?? const {});
  }

  factory FoodItem.fromMap(String id, Map<String, dynamic> data) {
    final rawExpiry = data['expiryDate'];
    final expiry = rawExpiry is Timestamp
        ? rawExpiry.toDate()
        : (rawExpiry is DateTime ? rawExpiry : DateTime.now());
    final rawQuantity = (data['quantity'] as num?)?.toInt() ?? 1;
    final parsedQuantity = rawQuantity < 1 ? 1 : rawQuantity;
    final rawOriginalQuantity = (data['originalQuantity'] as num?)?.toInt();
    final parsedOriginalQuantity =
        (rawOriginalQuantity != null && rawOriginalQuantity >= parsedQuantity)
            ? rawOriginalQuantity
            : null;
    final rawTotalPrice = (data['totalPrice'] as num?)?.toDouble();

    return FoodItem(
      id: id,
      name: (data['name'] as String?) ?? '',
      category: (data['category'] as String?) ?? 'Other',
      storageLocation: normalizeStorageLocation(data['storageLocation']),
      quantity: parsedQuantity,
      originalQuantity: parsedOriginalQuantity,
      totalPrice: rawTotalPrice,
      expiryDate: expiry,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'category': category,
      'storageLocation': storageLocation,
      'quantity': quantity,
      'originalQuantity': effectiveOriginalQuantity,
      'totalPrice': totalPrice,
      'expiryDate': Timestamp.fromDate(expiryDate),
    };
  }

  /// Date shown on screen, like 25/12/2026
  String get expiryText {
    final local = normalizeDateOnly(expiryDate);
    final d = local.day.toString().padLeft(2, '0');
    final m = local.month.toString().padLeft(2, '0');
    return '$d/$m/${local.year}';
  }

  /// Calendar days remaining until [expiryDate] relative to [referenceNow]
  /// (negative = overdue/expired, 0 = expires today). Uses UTC calendar-date
  /// arithmetic so DST transitions and time-of-day differences never skew counts.
  int daysLeftAt([DateTime? referenceNow]) {
    final today = _utcCalendarDate(referenceNow ?? DateTime.now());
    final expiry = _utcCalendarDate(expiryDate);
    return expiry.difference(today).inDays;
  }

  /// Calendar days left until expiry (negative = already expired)
  int get daysLeft => daysLeftAt();

  static ExpiryAlertLevel alertLevelForDaysLeft(int daysRemaining) {
    if (daysRemaining < 0) return ExpiryAlertLevel.expired;
    if (daysRemaining == 0) return ExpiryAlertLevel.expiresToday;
    if (daysRemaining <= 3) return ExpiryAlertLevel.urgent;
    if (daysRemaining <= 7) return ExpiryAlertLevel.expiringSoon;
    return ExpiryAlertLevel.normal;
  }

  static String statusLabelForLevel(ExpiryAlertLevel level) {
    switch (level) {
      case ExpiryAlertLevel.normal:
        return 'Normal';
      case ExpiryAlertLevel.expiringSoon:
        return 'Expiring Soon';
      case ExpiryAlertLevel.urgent:
        return 'Urgent';
      case ExpiryAlertLevel.expiresToday:
        return 'Expires Today';
      case ExpiryAlertLevel.expired:
        return 'Expired';
    }
  }

  ExpiryAlertLevel alertLevelAt([DateTime? referenceNow]) =>
      alertLevelForDaysLeft(daysLeftAt(referenceNow));

  ExpiryAlertLevel get alertLevel => alertLevelAt();

  String statusAt([DateTime? referenceNow]) =>
      statusLabelForLevel(alertLevelAt(referenceNow));

  /// Dynamic expiry status:
  /// Normal (>7d), Expiring Soon (4-7d), Urgent (1-3d), Expires Today (0d), Expired (<0d)
  String get status => statusAt();

  String daysLeftTextAt([DateTime? referenceNow]) {
    final d = daysLeftAt(referenceNow);
    if (d < 0) {
      final ago = -d;
      return 'Expired $ago ${ago == 1 ? 'day' : 'days'} ago';
    }
    if (d == 0) return 'Expires Today';
    if (d == 1) return '1 day left';
    return '$d days left';
  }

  /// Text like "5 days left", "Expires Today", or "Expired 2 days ago"
  String get daysLeftText => daysLeftTextAt();
}

class ExpirySummary {
  final int normalCount;
  final int expiringSoonCount;
  final int urgentCount;
  final int expiresTodayCount;
  final int expiredCount;

  const ExpirySummary({
    required this.normalCount,
    required this.expiringSoonCount,
    required this.urgentCount,
    required this.expiresTodayCount,
    required this.expiredCount,
  });

  factory ExpirySummary.fromItems(
    Iterable<FoodItem> items, {
    DateTime? referenceNow,
  }) {
    var normal = 0;
    var expiringSoon = 0;
    var urgent = 0;
    var expiresToday = 0;
    var expired = 0;

    for (final item in items) {
      switch (item.alertLevelAt(referenceNow)) {
        case ExpiryAlertLevel.normal:
          normal++;
          break;
        case ExpiryAlertLevel.expiringSoon:
          expiringSoon++;
          break;
        case ExpiryAlertLevel.urgent:
          urgent++;
          break;
        case ExpiryAlertLevel.expiresToday:
          expiresToday++;
          break;
        case ExpiryAlertLevel.expired:
          expired++;
          break;
      }
    }

    return ExpirySummary(
      normalCount: normal,
      expiringSoonCount: expiringSoon,
      urgentCount: urgent,
      expiresTodayCount: expiresToday,
      expiredCount: expired,
    );
  }

  int get totalCount =>
      normalCount +
      expiringSoonCount +
      urgentCount +
      expiresTodayCount +
      expiredCount;

  bool get hasAlerts =>
      expiringSoonCount > 0 ||
      urgentCount > 0 ||
      expiresTodayCount > 0 ||
      expiredCount > 0;

  int countFor(ExpiryAlertLevel level) {
    switch (level) {
      case ExpiryAlertLevel.normal:
        return normalCount;
      case ExpiryAlertLevel.expiringSoon:
        return expiringSoonCount;
      case ExpiryAlertLevel.urgent:
        return urgentCount;
      case ExpiryAlertLevel.expiresToday:
        return expiresTodayCount;
      case ExpiryAlertLevel.expired:
        return expiredCount;
    }
  }

  String? get alertBannerMessage {
    if (!hasAlerts) return null;

    final segments = <String>[
      if (expiredCount > 0) '$expiredCount expired',
      if (expiresTodayCount > 0) '$expiresTodayCount expiring today',
      if (urgentCount > 0) '$urgentCount urgent',
      if (expiringSoonCount > 0) '$expiringSoonCount expiring soon',
    ];

    if (segments.length == 1) {
      if (expiredCount > 0) {
        return '$expiredCount ${expiredCount == 1 ? 'item has' : 'items have'} expired — review, use if safe, or discard.';
      }
      if (expiresTodayCount > 0) {
        return '$expiresTodayCount ${expiresTodayCount == 1 ? 'item expires' : 'items expire'} today — use today or check recipes.';
      }
      if (urgentCount > 0) {
        return '$urgentCount urgent ${urgentCount == 1 ? 'item' : 'items'} (1–3 days left) — use soon or check recipes.';
      }
      return '$expiringSoonCount ${expiringSoonCount == 1 ? 'item' : 'items'} expiring soon (4–7 days left) — plan ahead or check recipes.';
    }

    final joined = segments.length == 2
        ? '${segments[0]} and ${segments[1]}'
        : '${segments.sublist(0, segments.length - 1).join(', ')}, and ${segments.last}';
    return '$joined — review items or check recipes.';
  }
}
