import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/waste_log.dart';
import '../services/stats_service.dart';
import '../utils/price_formatter.dart';

class StatsSummary {
  final int totalConsumed;
  final int totalWasted;
  final int efficiency;
  final Map<String, int> wasteByCategory;
  final int pricedConsumedCount;
  final int pricedWastedCount;
  final int unpricedLogCount;
  final double? estimatedConsumedValue;
  final double? wasteCost;

  const StatsSummary({
    required this.totalConsumed,
    required this.totalWasted,
    required this.efficiency,
    required this.wasteByCategory,
    required this.pricedConsumedCount,
    required this.pricedWastedCount,
    required this.unpricedLogCount,
    required this.estimatedConsumedValue,
    required this.wasteCost,
  });

  factory StatsSummary.fromLogs(List<WasteLog> logs) {
    final consumedLogs = logs.where((l) => l.action == 'consumed').toList();
    final wastedLogs = logs.where((l) => l.action == 'wasted').toList();

    final totalConsumed =
        consumedLogs.fold<int>(0, (sum, l) => sum + l.quantity);
    final totalWasted = wastedLogs.fold<int>(0, (sum, l) => sum + l.quantity);
    final totalAll = totalConsumed + totalWasted;
    final efficiency =
        totalAll > 0 ? ((totalConsumed / totalAll) * 100).round() : 100;

    final wasteByCategory = <String, int>{};
    for (final log in wastedLogs) {
      wasteByCategory[log.category] =
          (wasteByCategory[log.category] ?? 0) + log.quantity;
    }

    final pricedConsumed =
        consumedLogs.where((l) => l.financialValue != null).toList();
    final pricedWasted =
        wastedLogs.where((l) => l.financialValue != null).toList();

    final consumedValue = pricedConsumed.isEmpty
        ? null
        : roundPrice(
            pricedConsumed.fold<double>(
              0,
              (sum, l) => sum + l.financialValue!,
            ),
          );
    final wasteValue = pricedWasted.isEmpty
        ? null
        : roundPrice(
            pricedWasted.fold<double>(
              0,
              (sum, l) => sum + l.financialValue!,
            ),
          );

    return StatsSummary(
      totalConsumed: totalConsumed,
      totalWasted: totalWasted,
      efficiency: efficiency,
      wasteByCategory: wasteByCategory,
      pricedConsumedCount: pricedConsumed.length,
      pricedWastedCount: pricedWasted.length,
      unpricedLogCount:
          logs.length - pricedConsumed.length - pricedWasted.length,
      estimatedConsumedValue: consumedValue,
      wasteCost: wasteValue,
    );
  }
}

class StatsScreen extends StatefulWidget {
  final String? userId;

  const StatsScreen({super.key, this.userId});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  late StatsService _statsService;
  late Stream<List<WasteLog>> _logsStream;

  @override
  void initState() {
    super.initState();
    _statsService = StatsService(userId: widget.userId);
    _logsStream = _statsService.streamLogs();
  }

  @override
  void didUpdateWidget(covariant StatsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _statsService = StatsService(userId: widget.userId);
      _logsStream = _statsService.streamLogs();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Waste & Consumption Stats'),
      ),
      body: StreamBuilder<List<WasteLog>>(
        stream: _logsStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Error: ${snapshot.error}'),
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final logs = snapshot.data ?? [];
          if (logs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bar_chart_outlined,
                        size: 72, color: colorScheme.outline),
                    const SizedBox(height: 16),
                    Text(
                      'No consumption data yet',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'When you consume or discard items from your pantry, FreshTrack tracks your stats here to help reduce food waste.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          final summary = StatsSummary.fromLogs(logs);
          final totalConsumed = summary.totalConsumed;
          final totalWasted = summary.totalWasted;
          final totalAll = totalConsumed + totalWasted;
          final efficiency = summary.efficiency;
          final wasteByCategory = summary.wasteByCategory;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Hero Summary Card
              Card(
                elevation: 0,
                color: colorScheme.primaryContainer.withOpacity(0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Text(
                        'Food Efficiency Score',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '$efficiency%',
                        style: theme.textTheme.displayMedium?.copyWith(
                          color: efficiency >= 70
                              ? Colors.green.shade700
                              : Colors.orange.shade800,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        efficiency >= 80
                            ? '🌟 Excellent! You are minimizing food waste.'
                            : efficiency >= 50
                                ? '👍 Good progress! Keep utilizing expiring items.'
                                : '⚠️ High food waste detected. Check your expiring list!',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: totalAll > 0 ? (totalConsumed / totalAll) : 1,
                          minHeight: 12,
                          backgroundColor: Colors.red.shade300,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.green.shade600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // KPI Row: Consumed vs Wasted
              Row(
                children: [
                  Expanded(
                    child: Card(
                      color: Colors.green.shade50,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: Colors.green.shade300),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 20),
                        child: Column(
                          children: [
                            const Icon(Icons.check_circle_outline,
                                color: Colors.green, size: 36),
                            const SizedBox(height: 8),
                            Text(
                              '$totalConsumed',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                color: Colors.green.shade800,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Text('Items Consumed',
                                style: TextStyle(
                                    color: Colors.green,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Card(
                      color: Colors.red.shade50,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: Colors.red.shade300),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 20),
                        child: Column(
                          children: [
                            const Icon(Icons.delete_outline,
                                color: Colors.red, size: 36),
                            const SizedBox(height: 8),
                            Text(
                              '$totalWasted',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                color: Colors.red.shade800,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Text('Items Wasted',
                                style: TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Financial KPI Row: Estimated Food Value Consumed vs Waste Cost
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Card(
                        color: Colors.teal.shade50,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: Colors.teal.shade200),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 16),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.savings_outlined,
                                  color: Colors.teal.shade700, size: 28),
                              const SizedBox(height: 6),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  summary.estimatedConsumedValue != null
                                      ? formatPkr(summary.estimatedConsumedValue!)
                                      : '--',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    color: Colors.teal.shade900,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Estimated Food Value Consumed',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.teal.shade800,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Card(
                        color: Colors.deepOrange.shade50,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: Colors.deepOrange.shade200),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 16),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.money_off_csred_outlined,
                                  color: Colors.deepOrange.shade700, size: 28),
                              const SizedBox(height: 6),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  summary.wasteCost != null
                                      ? formatPkr(summary.wasteCost!)
                                      : '--',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    color: Colors.deepOrange.shade900,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Waste Cost',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.deepOrange.shade800,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (summary.unpricedLogCount > 0) ...[
                const SizedBox(height: 6),
                Text(
                  'Excludes ${summary.unpricedLogCount} unpriced '
                  '${summary.unpricedLogCount == 1 ? 'entry' : 'entries'} from Rs. totals.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.outline,
                  ),
                ),
              ],
              const SizedBox(height: 20),

              // Waste by Category
              if (wasteByCategory.isNotEmpty) ...[
                Text(
                  'Waste by Category',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  elevation: 0,
                  color: colorScheme.surfaceVariant.withOpacity(0.3),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: wasteByCategory.entries.map((entry) {
                        final percentage =
                            totalWasted > 0 ? (entry.value / totalWasted) : 0.0;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(entry.key,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  Text('${entry.value} items (${(percentage * 100).round()}%)'),
                                ],
                              ),
                              const SizedBox(height: 4),
                              LinearProgressIndicator(
                                value: percentage,
                                minHeight: 6,
                                borderRadius: BorderRadius.circular(4),
                                backgroundColor: colorScheme.surfaceVariant,
                                color: Colors.redAccent,
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // Recent Activity Log
              Text(
                'Recent Activity History',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              ...logs.take(15).map((log) {
                final isConsumed = log.action == 'consumed';
                final dateFormatted =
                    DateFormat('dd MMM yyyy, hh:mm a').format(log.timestamp);

                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: isConsumed
                          ? Colors.green.withOpacity(0.3)
                          : Colors.red.withOpacity(0.3),
                    ),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isConsumed
                          ? Colors.green.withOpacity(0.15)
                          : Colors.red.withOpacity(0.15),
                      child: Icon(
                        isConsumed ? Icons.restaurant : Icons.delete,
                        color: isConsumed ? Colors.green : Colors.red,
                        size: 20,
                      ),
                    ),
                    title: Text(
                      log.foodName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      '${log.category} • Qty: ${log.quantity}'
                      '${log.financialValue != null ? ' • ${formatPkr(log.financialValue!)}' : ''}'
                      '\n$dateFormatted',
                    ),
                    trailing: Chip(
                      label: Text(
                        isConsumed ? 'Consumed' : 'Wasted',
                        style: TextStyle(
                          color: isConsumed ? Colors.green.shade800 : Colors.red.shade800,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      backgroundColor: isConsumed
                          ? Colors.green.shade50
                          : Colors.red.shade50,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}
