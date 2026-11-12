import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/food_item.dart';
import '../models/shopping_item.dart';
import '../services/food_service.dart';
import '../services/shopping_service.dart';
import '../utils/price_formatter.dart';

class AddEditScreen extends StatefulWidget {
  final FoodItem? item; // null = add new, not null = edit
  final ShoppingItem? fromShoppingItem; // non-null = single-item restock
  final bool alreadyInPantryHint;
  final String? userId;

  const AddEditScreen({
    super.key,
    this.item,
    this.fromShoppingItem,
    this.alreadyInPantryHint = false,
    this.userId,
  });

  @override
  State<AddEditScreen> createState() => _AddEditScreenState();
}

class _AddEditScreenState extends State<AddEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _quantityController = TextEditingController(text: '1');
  final _priceController = TextEditingController();
  late final FoodService _service;
  late final ShoppingService _shoppingService;

  String _category = 'Other';
  String _storageLocation = FoodItem.defaultStorageLocation;
  DateTime? _expiryDate;
  String? _dateError;
  bool _saving = false;

  bool get _isEditing => widget.item != null;
  bool get _isRestocking => widget.fromShoppingItem != null && widget.item == null;

  @override
  void initState() {
    super.initState();
    _service = FoodService(userId: widget.userId);
    _shoppingService = ShoppingService(userId: widget.userId);
    final item = widget.item;
    final shopItem = widget.fromShoppingItem;
    if (item != null) {
      _nameController.text = item.name;
      _quantityController.text = item.quantity.toString();
      if (item.totalPrice != null) {
        final price = item.totalPrice!;
        _priceController.text = (price - price.roundToDouble()).abs() < 0.005
            ? price.round().toString()
            : price.toStringAsFixed(2);
      }
      _category = FoodItem.normalizeCategory(item.category);
      _storageLocation =
          FoodItem.normalizeStorageLocation(item.storageLocation);
      _expiryDate = item.expiryDate;
    } else if (shopItem != null) {
      _nameController.text = shopItem.name;
      _quantityController.text = shopItem.quantity.toString();
      _category = FoodItem.normalizeCategory(shopItem.category);
      _storageLocation =
          FoodItem.normalizeStorageLocation(shopItem.storageLocation);
      _expiryDate = null;
    }
  }

  IconData _storageIcon(String location) {
    switch (location) {
      case 'Fridge':
        return Icons.kitchen_outlined;
      case 'Freezer':
        return Icons.ac_unit;
      default:
        return Icons.inventory_2_outlined;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  String? _priceHelperText() {
    final enteredQty = int.tryParse(_quantityController.text.trim());
    final rawPriceText = _priceController.text.trim();
    final parsedPrice =
        rawPriceText.isEmpty ? null : double.tryParse(rawPriceText);
    final hasInvalidPrice =
        rawPriceText.isNotEmpty && (parsedPrice == null || parsedPrice <= 0);
    if (hasInvalidPrice) return null;

    final existing = widget.item;
    if (existing != null && existing.isPartiallyConsumed) {
      final qtyChanged = enteredQty != null && enteredQty != existing.quantity;
      final priceChanged =
          !optionalPricesEqual(parsedPrice, existing.totalPrice);
      if (!qtyChanged && !priceChanged) {
        if (existing.totalPrice != null && existing.estimatedUnitPrice != null) {
          return 'Original entry: ${existing.effectiveOriginalQuantity} units • '
              '${formatPkr(existing.totalPrice!)} '
              '(${formatPkr(existing.estimatedUnitPrice!)}/unit). '
              'Kept unless quantity or price changes.';
        }
        return 'Originally ${existing.effectiveOriginalQuantity} units '
            '(${existing.quantity} remaining).';
      }
      if (enteredQty != null && enteredQty >= 1) {
        if (parsedPrice != null && parsedPrice > 0) {
          return 'New baseline on save: $enteredQty unit(s) at '
              '${formatPkr(parsedPrice)} '
              '(${formatPkr(parsedPrice / enteredQty)}/unit). Past logs unchanged.';
        }
        return 'New baseline on save: $enteredQty unit(s) (no price tracked). '
            'Past logs unchanged.';
      }
      return null;
    }

    if (enteredQty != null &&
        enteredQty >= 1 &&
        parsedPrice != null &&
        parsedPrice > 0) {
      return 'Estimated unit value: ${formatPkr(parsedPrice / enteredQty)}';
    }
    return null;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = _isRestocking
        ? ((_expiryDate != null && !_expiryDate!.isBefore(today))
            ? _expiryDate!
            : today)
        : (_expiryDate ?? now);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: _isRestocking ? today : DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _expiryDate = picked;
        _dateError = null;
      });
    }
  }

  String _dateText() {
    final d = _expiryDate;
    if (d == null) {
      return _isRestocking ? 'Choose expiry date *' : 'Choose expiry date';
    }
    final day = d.day.toString().padLeft(2, '0');
    final month = d.month.toString().padLeft(2, '0');
    return '$day/$month/${d.year}';
  }

  Future<void> _save() async {
    final validForm = _formKey.currentState!.validate();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (_expiryDate == null) {
      setState(() => _dateError = 'Please choose an expiry date');
      if (validForm) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please choose an expiry date')),
        );
      }
      return;
    }
    if (_isRestocking &&
        DateTime(_expiryDate!.year, _expiryDate!.month, _expiryDate!.day)
            .isBefore(today)) {
      setState(() => _dateError = 'Expiry date cannot be in the past');
      return;
    }
    if (!validForm) return;

    setState(() {
      _saving = true;
      _dateError = null;
    });
    try {
      final d = _expiryDate!;
      final expiryOnly = DateTime(d.year, d.month, d.day);
      final rawPriceText = _priceController.text.trim();
      final rawPrice =
          rawPriceText.isEmpty ? null : double.tryParse(rawPriceText);
      final enteredQty = int.parse(_quantityController.text.trim());

      final cleanedName = FoodItem.cleanDisplayName(_nameController.text);

      if (_isRestocking) {
        final result = await _shoppingService.restockItems([
          RestockEntry(
            shoppingItem: widget.fromShoppingItem!,
            name: cleanedName,
            category: _category,
            quantity: enteredQty,
            storageLocation: _storageLocation,
            expiryDate: expiryOnly,
            totalPrice: rawPrice,
          ),
        ]);
        if (!mounted) return;
        Navigator.pop(context, result);
        return;
      }

      final item = FoodItem.buildForSave(
        existing: widget.item,
        name: cleanedName,
        category: _category,
        storageLocation: _storageLocation,
        quantity: enteredQty,
        totalPrice: rawPrice,
        expiryDate: expiryOnly,
      );

      // Await the Firestore transaction so it is committed before popping
      FoodUpdateResult? updateResult;
      if (_isEditing) {
        updateResult = await _service.updateItem(item);
      } else {
        await _service.addItem(item);
      }

      if (!mounted) return;
      Navigator.pop(context, updateResult);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save item: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenTitle = _isEditing
        ? 'Edit item'
        : _isRestocking
            ? 'Move to Pantry'
            : 'Add item';
    final submitLabel = _isEditing
        ? 'Update'
        : _isRestocking
            ? 'Add to Pantry'
            : 'Save';

    return Scaffold(
      appBar: AppBar(title: Text(screenTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              if (_isRestocking && widget.alreadyInPantryHint) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          color: Colors.blue.shade700, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '"${widget.fromShoppingItem!.name}" is already in your Pantry. '
                          'Same storage, expiry date, and price mode will merge quantities cleanly.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.blue.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              TextFormField(
                controller: _nameController,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(FoodItem.maxNameLength),
                ],
                decoration: const InputDecoration(
                  labelText: 'Food name',
                  prefixIcon: Icon(Icons.fastfood_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final cleaned = FoodItem.cleanDisplayName(value ?? '');
                  if (cleaned.isEmpty) {
                    return 'Please enter the food name';
                  }
                  if (cleaned.length > FoodItem.maxNameLength) {
                    return 'Food name must be ${FoodItem.maxNameLength} characters or fewer';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  prefixIcon: Icon(Icons.category_outlined),
                  border: OutlineInputBorder(),
                ),
                items: FoodItem.categories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => _category = value);
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _storageLocation,
                decoration: InputDecoration(
                  labelText: 'Storage location',
                  prefixIcon: Icon(_storageIcon(_storageLocation)),
                  border: const OutlineInputBorder(),
                ),
                selectedItemBuilder: (context) => FoodItem.storageLocations
                    .map((loc) => Text(loc))
                    .toList(),
                items: FoodItem.storageLocations
                    .map(
                      (loc) => DropdownMenuItem(
                        value: loc,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_storageIcon(loc), size: 20),
                            const SizedBox(width: 8),
                            Text(loc),
                          ],
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => _storageLocation = value);
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _quantityController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Quantity',
                  prefixIcon: Icon(Icons.numbers),
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
                validator: (value) {
                  final n = int.tryParse(value?.trim() ?? '');
                  if (n == null || n < 1) {
                    return 'Enter a quantity of 1 or more';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _priceController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                ],
                decoration: InputDecoration(
                  labelText: 'Total price (Rs., optional)',
                  hintText: 'Leave blank if unknown',
                  prefixIcon: const Icon(Icons.payments_outlined),
                  border: const OutlineInputBorder(),
                  helperText: _priceHelperText(),
                  helperMaxLines: 3,
                ),
                onChanged: (_) => setState(() {}),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return null;
                  final parsed = double.tryParse(text);
                  if (parsed == null || parsed <= 0) {
                    return 'Enter a valid price above 0 or leave blank';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton.icon(
                  onPressed: _pickDate,
                  style: _dateError != null
                      ? OutlinedButton.styleFrom(
                          foregroundColor: Colors.red.shade700,
                          side: BorderSide(color: Colors.red.shade700),
                        )
                      : null,
                  icon: const Icon(Icons.calendar_today),
                  label: Text(_dateText()),
                ),
              ),
              if (_dateError != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _dateError!,
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : Text(submitLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
