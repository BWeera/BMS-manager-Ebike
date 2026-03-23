import 'dart:io';

void main() {
  final file = File('lib/main.dart');
  
  final newUi = r'''  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BMS Dashboard'),
        actions: [
          IconButton(
            icon: Icon(themeNotifier.value == ThemeMode.dark ? Icons.light_mode : Icons.dark_mode),
            onPressed: () {
              themeNotifier.value = themeNotifier.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
            },
          )
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                children: [
                  _MetricsPanel(metrics: _metrics),
                  const SizedBox(height: 14),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Last BLE Packet',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          Text('Raw packets: '),
                          Text('Echo packets: '),
                          Text('Parsed telemetry: '),
                          Text('Source: '),
                          const SizedBox(height: 6),
                          Text(_lastPacketHex),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            
            // Bottom Device Status and Scanning Module
            Material(
              elevation: 8,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _status,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (_connectedDevice == null && !_isScanning)
                            FilledButton.icon(
                              onPressed: _startScan,
                              icon: const Icon(Icons.bluetooth_searching, size: 18),
                              label: const Text('Scan'),
                            ),
                          if (_isScanning)
                            FilledButton.tonalIcon(
                              onPressed: _stopScan,
                              icon: const Icon(Icons.stop, size: 18),
                              label: const Text('Stop'),
                            ),
                          if (_connectedDevice != null)
                            OutlinedButton.icon(
                              onPressed: _disconnect,
                              icon: const Icon(Icons.bluetooth_disabled, size: 18),
                              label: const Text('Disconnect'),
                            ),
                        ],
                      ),
                      if (_connectedDevice == null && _scanResults.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.3),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: _scanResults.length,
                            itemBuilder: (context, index) {
                              final result = _scanResults[index];
                              return Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  dense: true,
                                  title: Text(result.device.platformName.isEmpty ? 'Unknown' : result.device.platformName),
                                  subtitle: Text('RSSI: '),
                                  trailing: FilledButton(
                                    onPressed: () => _connect(result),
                                    child: const Text('Connect'),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BatteryGauge extends StatelessWidget {
  final double percentage;

  const _BatteryGauge({required this.percentage});

  @override
  Widget build(BuildContext context) {
    final color = percentage > 50 ? Colors.green : (percentage > 20 ? Colors.orange : Colors.red);
    final theme = Theme.of(context);
    
    return Column(
      children: [
        Stack(
          alignment: Alignment.bottomCenter,
          clipBehavior: Clip.none,
          children: [
            // Battery Body
            Container(
              width: 100,
              height: 180,
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outline, width: 4),
                borderRadius: BorderRadius.circular(12),
                color: theme.colorScheme.surface,
              ),
            ),
            // Battery Level
            Positioned(
              bottom: 4,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 500),
                width: 92,
                height: 172 * (percentage / 100).clamp(0.0, 1.0),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            // Battery Cap
            Positioned(
              top: -8,
              child: Container(
                width: 40,
                height: 8,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outline,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                ),
              ),
            ),
            // Percentage Text
            Positioned.fill(
              child: Center(
                child: Text(
                  '%',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: percentage > 40 ? Colors.white : theme.colorScheme.onSurface,
                    shadows: percentage > 40 ? [
                      const Shadow(blurRadius: 2, color: Colors.black54)
                    ] : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MetricsPanel extends StatelessWidget {
  const _MetricsPanel({required this.metrics});

  final BmsMetrics? metrics;

  @override
  Widget build(BuildContext context) {
    final valueStyle = Theme.of(context).textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
        );

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Battery Fuel Gauge
            Padding(
              padding: const EdgeInsets.only(top: 8.0, bottom: 24.0),
              child: _BatteryGauge(percentage: metrics?.batteryPercent ?? 0.0),
            ),
            
            // Grid of other metrics
            Row(
              children: [
                Expanded(child: _metricTile(context, 'Voltage', metrics?.voltageString ?? '-- V', Icons.bolt, valueStyle)),
                const SizedBox(width: 12),
                Expanded(child: _metricTile(context, 'Current', metrics?.currentString ?? '-- A', Icons.speed, valueStyle)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _metricTile(context, 'Power', metrics?.wattageString ?? '-- W', Icons.electric_meter, valueStyle)),
              ],
            ),
            if (metrics != null) ...[
              const SizedBox(height: 16),
              Divider(color: Theme.of(context).colorScheme.outlineVariant),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Updated: ::', style: Theme.of(context).textTheme.bodySmall),
                  Text(metrics!.parserHint, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metricTile(BuildContext context, String label, String value, IconData icon, TextStyle? valueStyle) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Text(label, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Text(value, style: valueStyle?.copyWith(color: Theme.of(context).colorScheme.onSurface)),
        ],
      ),
    );
  }
}

''';

  file.writeAsStringSync(newUi, mode: FileMode.append);
  print('Part 1 appended');
}
