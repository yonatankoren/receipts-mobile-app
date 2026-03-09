/// Sync status indicator — shows pending uploads count and sync activity.
/// Displayed in the camera screen top bar and receipts list app bar.

import 'package:flutter/material.dart';
import '../services/sync_engine.dart';
import 'loading_indicator.dart';

class SyncStatusIndicator extends StatelessWidget {
  const SyncStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncEngine.instance,
      builder: (context, _) {
        final engine = SyncEngine.instance;

        if (engine.pendingCount == 0 && !engine.isRunning) {
          // All synced — show green dot
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_done, color: Colors.green, size: 16),
                SizedBox(width: 4),
                Text(
                  'מסונכרן',
                  style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          );
        }

        // Has pending items or is actively syncing
        final isActive = engine.isRunning;
        final color = isActive ? Colors.blue : Colors.orange;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isActive)
                LoadingIndicator(
                  compact: true,
                  size: 14,
                  color: color,
                )
              else
                Icon(Icons.cloud_upload, color: color, size: 16),
              const SizedBox(width: 4),
              Text(
                engine.pendingCount > 0
                    ? '${engine.pendingCount} ממתינים'
                    : 'מסנכרן...',
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

