import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../bloc/band_monitor_bloc.dart';
import '../../bloc/band_monitor_event.dart';
import '../../bloc/band_monitor_state.dart';

/// Bottom sheet for displaying BLE scan results and connecting to a device.
class DeviceScanSheet extends StatelessWidget {
  const DeviceScanSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            'Nearby Smartband Devices',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Ensure Bluetooth & Location (GPS) are enabled and band is nearby…',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 20),
          BlocBuilder<BandMonitorBloc, BandMonitorState>(
            builder: (context, state) {
              if (state is BandScanningState && state.results.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Column(
                      children: [
                        const CircularProgressIndicator(
                            color: Color(0xFF1A73E8)),
                        const SizedBox(height: 16),
                        Text(
                          'Looking for nearby G-Band devices…',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                              fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                );
              }

              final rawResults = state is BandScanningState ? state.results : [];
              final List<VpScanResult> results = List<VpScanResult>.from(rawResults);
              
              // Sort known bands (MF91, JCV5, G-BAND, VEEPOO etc.) to the top
              results.sort((a, b) {
                final aKnown = _isKnownBand(a.name);
                final bKnown = _isKnownBand(b.name);
                if (aKnown && !bKnown) return -1;
                if (!aKnown && bKnown) return 1;
                return a.name.compareTo(b.name);
              });

              return Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: results.length,
                  separatorBuilder: (_, __) => Divider(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
                    height: 1,
                  ),
                  itemBuilder: (context, i) {
                    final r = results[i];
                    final name = r.name.isNotEmpty ? r.name : 'Unknown Device (${r.mac})';
                    final isKnown = _isKnownBand(r.name);

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 0, vertical: 4),
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: (isKnown ? const Color(0xFF1A73E8) : Colors.grey)
                              .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.watch_rounded,
                            color: isKnown ? const Color(0xFF1A73E8) : Colors.grey,
                            size: 22),
                      ),
                      title: Text(
                        name,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      subtitle: Text(
                        r.mac,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                      trailing: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1A73E8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                        ),
                        onPressed: () {
                          Navigator.pop(context);
                          context
                              .read<BandMonitorBloc>()
                              .add(ConnectToBand(r.mac, r.name.isNotEmpty ? r.name : 'G-Band'));
                        },
                        child: const Text('Connect',
                            style: TextStyle(fontSize: 13)),
                      ),
                    );
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                side: BorderSide(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: () {
                context.read<BandMonitorBloc>().add(const StopScan());
                Navigator.pop(context);
              },
              child: const Text('Cancel'),
            ),
          ),
        ],
      ),
    );
  }

  static bool _isKnownBand(String name) {
    if (name.isEmpty) return false;
    final upper = name.toUpperCase();
    const prefixes = [
      'MF91', 'JCV5', 'GBAND', 'G-BAND', 'VEEPOO', 'VP', 'E66', 'B36',
      'V100', 'JSTYLE', 'BAND', 'SMART', 'WATCH'
    ];
    return prefixes.any((p) => upper.contains(p));
  }
}
