import 'package:intl/intl.dart';

final NumberFormat _wholePkrFormat = NumberFormat('#,##0', 'en_US');
final NumberFormat _decimalPkrFormat = NumberFormat('#,##0.00', 'en_US');

double roundPrice(double value) {
  return (value * 100).roundToDouble() / 100;
}

double? normalizeOptionalPrice(double? value) {
  if (value == null || value.isNaN || value.isInfinite || value <= 0) {
    return null;
  }
  return roundPrice(value);
}

bool optionalPricesEqual(double? a, double? b) {
  final na = normalizeOptionalPrice(a);
  final nb = normalizeOptionalPrice(b);
  if (na == null && nb == null) return true;
  if (na == null || nb == null) return false;
  return (na - nb).abs() < 0.005;
}

String formatPkr(double value) {
  final rounded = roundPrice(value);
  if ((rounded - rounded.roundToDouble()).abs() < 0.005) {
    return 'Rs. ${_wholePkrFormat.format(rounded.round())}';
  }
  return 'Rs. ${_decimalPkrFormat.format(rounded)}';
}
