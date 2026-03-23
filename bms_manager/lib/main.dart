import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BmsManagerApp());
}

class BmsManagerApp extends StatelessWidget {
  const BmsManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, themeMode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'eBike BMS',
          themeMode: themeMode,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0A8F6A),
              brightness: Brightness.light,
            ),
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0A8F6A),
              brightness: Brightness.dark,
            ),
          ),
          home: const BmsDashboardPage(),
        );
      },
    );
  }
}

class BmsDashboardPage extends StatefulWidget {
  const BmsDashboardPage({super.key});

  @override
  State<BmsDashboardPage> createState() => _BmsDashboardPageState();
}

class _BmsDashboardPageState extends State<BmsDashboardPage> {
  static const List<List<int>> _pollCommands = <List<int>>[
    // JBD/Xiaoxiang Default
    [0xDD, 0xA5, 0x03, 0x00, 0xFF, 0xFD, 0x77],
    [0xDD, 0xA5, 0x04, 0x00, 0xFF, 0xFC, 0x77],
    [0xDD, 0xA5, 0x05, 0x00, 0xFF, 0xFB, 0x77],
    // Daly Generic 0x90 (Volt/Curr/SOC)
    [0xA5, 0x40, 0x90, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7D],
  ];

  final List<ScanResult> _scanResults = [];

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  final List<StreamSubscription<List<int>>> _notifySubscriptions = [];
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  Timer? _pollTimer;

  BluetoothDevice? _connectedDevice;
  final List<BluetoothCharacteristic> _notifyCharacteristics = [];
  final List<BluetoothCharacteristic> _writeCharacteristics = [];
  final List<BluetoothCharacteristic> _readCharacteristics = [];
  BmsMetrics? _metrics;
  String _status = 'Ready';
  String _lastPacketHex = '-';
  String _lastPacketSource = '-';
  int _packetCount = 0;
  int _rawPacketCount = 0;
  int _echoPacketCount = 0;
  bool _isScanning = false;

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _cancelNotifySubscriptions();
    _connectionSubscription?.cancel();
    _pollTimer?.cancel();
    _disconnect();
    super.dispose();
  }

  Future<void> _ensureBluetoothPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final denied = statuses.values.any((status) => !status.isGranted);
    if (denied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bluetooth permissions are required to read BMS data.'),
        ),
      );
    }
  }

  Future<void> _startScan() async {
    await _ensureBluetoothPermissions();
    _scanResults.clear();

    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) {
        return;
      }

      final filtered = results.where((result) {
        final name = result.device.platformName.toLowerCase();
        return name.contains('bms') || name.contains('smart') || name.isNotEmpty;
      }).toList();

      setState(() {
        _scanResults
          ..clear()
          ..addAll(filtered);
      });
    });

    setState(() {
      _isScanning = true;
      _status = 'Scanning...';
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    if (!mounted) {
      return;
    }

    setState(() {
      _isScanning = false;
      _status = _scanResults.isEmpty ? 'No device found' : 'Select a device';
    });
  }

  Future<void> _stopScan() async {
    await FlutterBluePlus.stopScan();
    if (!mounted) {
      return;
    }
    setState(() {
      _isScanning = false;
      _status = 'Scan stopped';
    });
  }

  Future<void> _connect(ScanResult result) async {
    await _stopScan();
    await _disconnect();

    final device = result.device;
    setState(() {
      _status = 'Connecting to ${device.platformName}...';
    });

    try {
      await device.connect(timeout: const Duration(seconds: 15));
      _connectionSubscription = device.connectionState.listen((state) {
        if (!mounted) {
          return;
        }
        setState(() {
          _status = switch (state) {
            BluetoothConnectionState.connected =>
              'Connected: ${device.platformName}',
            BluetoothConnectionState.disconnected => 'Disconnected',
            _ => 'Connection state: ${state.name}',
          };
        });
      });

      final services = await device.discoverServices();
      _notifyCharacteristics
        ..clear()
        ..addAll(
          services
              .expand((service) => service.characteristics)
              .where(
                (characteristic) =>
                    (characteristic.properties.notify ||
                        characteristic.properties.indicate) &&
                    _isLikelyBmsNotifyCharacteristic(characteristic),
              ),
        );
      _writeCharacteristics
        ..clear()
        ..addAll(
          services
              .expand((service) => service.characteristics)
              .where(
                (characteristic) =>
                    (characteristic.properties.write ||
                        characteristic.properties.writeWithoutResponse) &&
                    _isLikelyBmsWriteCharacteristic(characteristic),
              ),
        );
            _readCharacteristics
              ..clear()
              ..addAll(
                services
                .expand((service) => service.characteristics)
                .where(
                  (characteristic) =>
                  characteristic.properties.read &&
                  _isLikelyBmsReadCharacteristic(characteristic),
                ),
              );

      _writeCharacteristics.sort((a, b) {
        final aScore = _writePriority(a);
        final bScore = _writePriority(b);
        return bScore.compareTo(aScore);
      });

      if (_notifyCharacteristics.isEmpty) {
        setState(() {
          _status =
              'Connected, but no notify characteristic found. Try another BMS.';
          _connectedDevice = device;
        });
        return;
      }

      await _cancelNotifySubscriptions();
      for (final characteristic in _notifyCharacteristics) {
        await characteristic.setNotifyValue(true);
        debugPrint(
          'Subscribed notify on ${characteristic.characteristicUuid.str}',
        );
        final subscription = characteristic.lastValueStream.listen((raw) {
          if (raw.isEmpty) {
            return;
          }
          _handleIncomingPacket(raw, characteristic.characteristicUuid.str, device);
        });
        _notifySubscriptions.add(subscription);
      }

      _startPolling();

      setState(() {
        _connectedDevice = device;
        _status =
        'Connected. Listening on ${_notifyCharacteristics.length} notify, ${_readCharacteristics.length} read characteristics';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Connection failed: $error';
      });
    }
  }

  Future<void> _disconnect() async {
    await _cancelNotifySubscriptions();
    _pollTimer?.cancel();
    _pollTimer = null;

    await _connectionSubscription?.cancel();
    _connectionSubscription = null;

    final device = _connectedDevice;
    _connectedDevice = null;
    _notifyCharacteristics.clear();
    _writeCharacteristics.clear();
    _readCharacteristics.clear();
    _metrics = null;
    _lastPacketHex = '-';
    _lastPacketSource = '-';
    _packetCount = 0;
    _rawPacketCount = 0;
    _echoPacketCount = 0;

    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {
        // Ignore disconnect errors.
      }
    }

    if (mounted) {
      setState(() {
        _status = 'Disconnected';
      });
    }
  }

  Future<void> _cancelNotifySubscriptions() async {
    for (final subscription in _notifySubscriptions) {
      await subscription.cancel();
    }
    _notifySubscriptions.clear();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _sendPollCommands();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 2000),
      (_) => _sendPollCommands(),
    );
  }

  Future<void> _sendPollCommands() async {
    if (_writeCharacteristics.isNotEmpty) {
      // Common SMART/JBD read commands.
      final candidates = _writeCharacteristics.take(2).toList();

      for (final command in _pollCommands) {
        for (final target in candidates) {
          final uuid = target.characteristicUuid.str.toLowerCase();

          try {
            if (target.properties.writeWithoutResponse) {
              await target.write(command, withoutResponse: true);
            } else if (target.properties.write) {
              await target.write(command, withoutResponse: false);
            }
            debugPrint(
              'Sent poll ${_toHex(command)} to ${target.characteristicUuid.str}',
            );
          } catch (_) {
            // Ignore intermittent write errors while polling.
          }

          if (uuid.endsWith('ff01')) {
            final asciiHex = _toHex(command).replaceAll(' ', '');
            final asciiPayload = asciiHex.codeUnits;
            try {
              if (target.properties.writeWithoutResponse) {
                await target.write(asciiPayload, withoutResponse: true);
              } else if (target.properties.write) {
                await target.write(asciiPayload, withoutResponse: false);
              }
              debugPrint(
                'Sent ASCII poll $asciiHex to ${target.characteristicUuid.str}',
              );
            } catch (_) {
              // Ignore intermittent write errors while polling.
            }
          }
        }
      }
    }

    await _pollReadCharacteristics();
  }

  Future<void> _pollReadCharacteristics() async {
    final device = _connectedDevice;
    if (device == null || _readCharacteristics.isEmpty) {
      return;
    }

    final candidates = _readCharacteristics.take(3).toList();
    for (final characteristic in candidates) {
      try {
        final raw = await characteristic.read();
        if (raw.isNotEmpty) {
          _handleIncomingPacket(
            raw,
            '${characteristic.characteristicUuid.str} [read]',
            device,
          );
          debugPrint(
            'Read packet from ${characteristic.characteristicUuid.str}: ${_toHex(raw)}',
          );
        }
      } catch (_) {
        // Some characteristics do not support active reads despite flags.
      }
    }
  }

  void _handleIncomingPacket(
    List<int> raw,
    String source,
    BluetoothDevice device,
  ) {
    if (!mounted) {
      return;
    }

    setState(() {
      _rawPacketCount++;
      _lastPacketHex = _toHex(raw);
      _lastPacketSource = source;
      _connectedDevice = device;
    });

    if (_isPollEcho(raw)) {
      setState(() {
        _echoPacketCount++;
        _status = 'Connected. Polling BMS, waiting for telemetry response';
      });
      return;
    }

    final metrics = BmsDecoder.decode(raw);
    setState(() {
      if (metrics != null) {
        _packetCount++;
        _metrics = metrics;
        _status = 'Live data parsed (${metrics.parserHint}) from $source';
      } else {
        _status = 'Receiving non-echo packets, parser not matched yet';
      }
    });
  }

  bool _isLikelyBmsNotifyCharacteristic(BluetoothCharacteristic characteristic) {
    final uuid = characteristic.characteristicUuid.str.toLowerCase();
    const blacklist = {'00002a05-0000-1000-8000-00805f9b34fb'};
    if (blacklist.contains(uuid)) {
      return false;
    }

    if (uuid.contains('fff') || uuid.contains('ff0') || uuid.contains('02f0')) {
      return true;
    }

    // Keep non-standard notify characteristics as fallback.
    return !uuid.contains('00002a');
  }

  bool _isLikelyBmsWriteCharacteristic(BluetoothCharacteristic characteristic) {
    final uuid = characteristic.characteristicUuid.str.toLowerCase();
    if (uuid == '00002a00-0000-1000-8000-00805f9b34fb') {
      return false;
    }
    if (uuid.endsWith('ff04')) {
      return false;
    }
    return uuid.contains('fff') ||
        uuid.contains('ff0') ||
        uuid.contains('02f0') ||
        !uuid.contains('00002a');
  }

  bool _isLikelyBmsReadCharacteristic(BluetoothCharacteristic characteristic) {
    final uuid = characteristic.characteristicUuid.str.toLowerCase();
    if (uuid.startsWith('00002a')) {
      return false; // Standard GATT
    }
    // Avoid reading static descriptor strings (e.g. fff3 containing 'spss_rx2_des')
    if (uuid.contains('fff3') || uuid.contains('fff4')) {
      return false;
    }
    return uuid.contains('fff') || uuid.contains('ff0') || uuid.contains('02f0');
  }

  int _writePriority(BluetoothCharacteristic characteristic) {
    final uuid = characteristic.characteristicUuid.str.toLowerCase();
    if (uuid.contains('fff2') || uuid.contains('ff02')) {
      return 100;
    }
    if (uuid.contains('fff1') || uuid.contains('ff01')) {
      return 90;
    }
    if (uuid.contains('02f0')) {
      return 80;
    }
    if (uuid.contains('fff')) {
      return 70;
    }
    return 10;
  }

  bool _isPollEcho(List<int> raw) {
    for (final command in _pollCommands) {
      if (_sameBytes(raw, command)) {
        return true;
      }

      final asciiHex = _toHex(command).replaceAll(' ', '');
      if (_sameBytes(raw, asciiHex.codeUnits)) {
        return true;
      }
    }
    return false;
  }

  @override
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
                          Text('Raw packets: $_rawPacketCount'),
                          Text('Echo packets: $_echoPacketCount'),
                          Text('Parsed telemetry: $_packetCount'),
                          Text('Source: $_lastPacketSource'),
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
                                  subtitle: Text('RSSI: ${result.rssi}'),
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
                  '${percentage.toStringAsFixed(1)}%',
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
                  Text('Updated: ${metrics!.timestamp.hour.toString().padLeft(2, '0')}:${metrics!.timestamp.minute.toString().padLeft(2, '0')}:${metrics!.timestamp.second.toString().padLeft(2, '0')}', style: Theme.of(context).textTheme.bodySmall),
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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

class BmsMetrics {
  BmsMetrics({
    required this.batteryPercent,
    required this.voltage,
    required this.current,
    required this.timestamp,
    required this.parserHint,
  });

  final double batteryPercent;
  final double voltage;
  final double current;
  final DateTime timestamp;
  final String parserHint;

  double get wattage => voltage * current;

  String get batteryPercentString => '${batteryPercent.toStringAsFixed(1)} %';
  String get voltageString => '${voltage.toStringAsFixed(2)} V';
  String get currentString => '${current.toStringAsFixed(2)} A';
  String get wattageString => '${wattage.toStringAsFixed(1)} W';
}

class BmsDecoder {
  static BmsMetrics? decode(List<int> raw) {
    final jbd = _parseJbdBasicInfo(raw);
    if (jbd != null) {
      return jbd;
    }

    final ascii = _parseAsciiPayload(raw);
    if (ascii != null) {
      return ascii;
    }

    final daly = _parseDalyLikePayload(raw);
    if (daly != null) {
      return daly;
    }

    final generic = _parseGenericFrame(raw);
    if (generic != null) {
      return generic;
    }

    return null;
  }

  static BmsMetrics? _parseJbdBasicInfo(List<int> raw) {
    if (raw.length < 7 || raw[0] != 0xDD || raw[1] != 0x03) {
      return null;
    }

    final payloadLength = raw[2];
    final expectedLength = payloadLength + 7;
    if (payloadLength <= 0 || raw.length < expectedLength) {
      return null;
    }

    final payload = raw.sublist(3, 3 + payloadLength);
    if (payload.length < 20) {
      return null;
    }

    final voltageRaw = (payload[0] << 8) | payload[1];
    final currentRaw = _toInt16((payload[2] << 8) | payload[3]);

    final voltage = voltageRaw / 100.0;
    final current = currentRaw / 100.0;

    final nominalCapacityRaw = ((payload[6] << 8) | payload[7]).toDouble();
    final remainingCapacityRaw = ((payload[4] << 8) | payload[5]).toDouble();
    final socFromCapacity = nominalCapacityRaw > 0
        ? (remainingCapacityRaw / nominalCapacityRaw) * 100.0
        : 0.0;
    final socFromByte = payload[19].toDouble();
    final soc = (socFromByte > 0 ? socFromByte : socFromCapacity)
        .clamp(0.0, 100.0);

    if (voltage <= 0 || voltage > 200) {
      return null;
    }

    return BmsMetrics(
      batteryPercent: soc,
      voltage: voltage,
      current: current,
      timestamp: DateTime.now(),
      parserHint: 'JBD basic info frame',
    );
  }

  static BmsMetrics? _parseAsciiPayload(List<int> raw) {
    final text = utf8.decode(raw, allowMalformed: true).trim();
    if (text.isEmpty) {
      return null;
    }

    final keyValueRegex = RegExp(r'(soc|battery|v|volt|a|amp|current)\s*[:=]\s*(-?\d+(?:\.\d+)?)',
        caseSensitive: false);
    final matches = keyValueRegex.allMatches(text);
    if (matches.isEmpty) {
      return null;
    }

    double? soc;
    double? voltage;
    double? current;

    for (final match in matches) {
      final key = (match.group(1) ?? '').toLowerCase();
      final value = double.tryParse(match.group(2) ?? '');
      if (value == null) {
        continue;
      }
      if (key == 'soc' || key == 'battery') {
        soc = value;
      }
      if (key == 'v' || key == 'volt') {
        voltage = value;
      }
      if (key == 'a' || key == 'amp' || key == 'current') {
        current = value;
      }
    }

    if (soc == null || voltage == null || current == null) {
      return null;
    }

    return BmsMetrics(
      batteryPercent: soc,
      voltage: voltage,
      current: current,
      timestamp: DateTime.now(),
      parserHint: 'ASCII key-value',
    );
  }

  static BmsMetrics? _parseDalyLikePayload(List<int> raw) {
    // Basic Daly Frame check: Start Mark A5, Module Address 01, Command 90, Data Len 08 (13 bytes total)
    if (raw.length < 13 || raw[0] != 0xA5 || raw[1] != 0x01 || raw[2] != 0x90) {
      return null;
    }

    final bytes = Uint8List.fromList(raw);
    final byteData = ByteData.sublistView(bytes);

    final voltageRaw = byteData.getUint16(4, Endian.big);
    final currentRaw = byteData.getUint16(8, Endian.big);
    final socRaw = byteData.getUint16(10, Endian.big);

    final voltage = voltageRaw / 10.0;
    final current = (currentRaw - 30000) / 10.0; // Offset 30000 -> 0A
    final soc = socRaw / 10.0;

    if (soc < 0 || soc > 100 || voltage <= 0) {
      return null;
    }

    return BmsMetrics(
      batteryPercent: soc,
      voltage: voltage,
      current: current,
      timestamp: DateTime.now(),
      parserHint: 'Daly BMS frame 0x90',
    );
  }

  static BmsMetrics? _parseGenericFrame(List<int> raw) {
    if (raw.length < 5) {
      return null;
    }

    final bytes = Uint8List.fromList(raw);
    final byteData = ByteData.sublistView(bytes);

    final voltage = byteData.getUint16(0, Endian.little) / 100.0;
    final current = byteData.getInt16(2, Endian.little) / 100.0;
    final soc = raw[4].toDouble();

    if (soc < 0 || soc > 100 || voltage <= 0 || voltage > 120) {
      return null;
    }

    return BmsMetrics(
      batteryPercent: soc,
      voltage: voltage,
      current: current,
      timestamp: DateTime.now(),
      parserHint: 'Generic LE 5-byte frame',
    );
  }

}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

int _toInt16(int value) {
  if ((value & 0x8000) != 0) {
    return value - 0x10000;
  }
  return value;
}

String _toHex(List<int> bytes) {
  return bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}
