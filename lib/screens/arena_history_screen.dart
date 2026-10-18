import 'package:flutter/material.dart';

import '../models/arena_models.dart';
import '../models/arena_run.dart';
import 'arena_explainer_screen.dart';
import '../services/arena_scoring.dart';
import '../services/benchmark_service.dart';

/// Saved Arena runs (Pro). Reads the user's private `arena_runs` history from
/// Firestore and lets them revisit the full scoring breakdown or delete a run.
class ArenaHistoryScreen extends StatefulWidget {
  const ArenaHistoryScreen({super.key});

  @override
  State<ArenaHistoryScreen> createState() => _ArenaHistoryScreenState();
}

class _ArenaHistoryScreenState extends State<ArenaHistoryScreen> {
  late Future<List<ArenaRun>> _future;

  @override
  void initState() {
    super.initState();
    _future = BenchmarkService.instance.fetchHistory();
  }

  Future<void> _refresh() async {
    setState(() {
      _future = BenchmarkService.instance.fetchHistory();
    });
    await _future;
  }

  void _open(ArenaRun run) {
    final board = ArenaScoring.score(run.results);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArenaExplainerScreen(
          results: run.results,
          scoreboard: board,
          userPickId: run.userPickId,
        ),
      ),
    );
  }

  Future<void> _delete(ArenaRun run) async {
    await BenchmarkService.instance.deleteRun(run.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Arena history')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<ArenaRun>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final runs = snap.data ?? [];
            if (runs.isEmpty) {
              return ListView(
                children: [
                  const SizedBox(height: 120),
                  Icon(Icons.history,
                      size: 56, color: theme.colorScheme.outlineVariant),
                  const SizedBox(height: 16),
                  Center(
                    child: Text('No saved runs yet',
                        style: theme.textTheme.titleMedium),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      'Run a benchmark or comparison and it will be saved here '
                      'automatically.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: runs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _runTile(context, runs[i]),
            );
          },
        ),
      ),
    );
  }

  Widget _runTile(BuildContext context, ArenaRun run) {
    final theme = Theme.of(context);
    final winner =
        run.winnerId != null ? _winnerName(run) : null;
    return Dismissible(
      key: ValueKey(run.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.delete_outline, color: theme.colorScheme.onErrorContainer),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Delete run?'),
                content: const Text('This removes it from your history.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete')),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) => _delete(run),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.14),
            child: Icon(
              run.mode == ArenaMode.benchmark
                  ? Icons.speed
                  : Icons.compare_arrows,
              color: theme.colorScheme.primary,
            ),
          ),
          title: Text(run.promptLabel,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${run.contestantCount} models · ${run.deviceName}\n'
            '${_formatDate(run.createdAt)}'
            '${winner != null ? ' · winner: $winner' : ''}',
            style: theme.textTheme.bodySmall,
          ),
          isThreeLine: true,
          onTap: () => _open(run),
        ),
      ),
    );
  }

  String _winnerName(ArenaRun run) {
    for (final r in run.results) {
      if (r.contestant.id == run.winnerId) return r.contestant.displayName;
    }
    return '';
  }

  static String _formatDate(DateTime d) {
    final local = d.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$day $hh:$mm';
  }
}
