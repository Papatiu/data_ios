import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// Proje içindeki servisler (senin uygulamanın gerçek implementasyonlarını kullan)
import 'multipeer_service.dart';
import 'mesh/mesh_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: PermissionGateway(),
    );
  }
}

class PermissionGateway extends StatefulWidget {
  const PermissionGateway({super.key});
  @override
  State<PermissionGateway> createState() => _PermissionGatewayState();
}

class _PermissionGatewayState extends State<PermissionGateway> {
  final MethodChannel _nativeChannel = const MethodChannel('com.example.multipeer/methods');
  bool _isChecking = true;

  @override
  void initState() {
    super.initState();
    _handlePermissions();
  }

  Future<Map<String, dynamic>?> _getNativePermissionStatus() async {
    try {
      final res = await _nativeChannel.invokeMethod('getNativePermissions');
      if (res is Map) return Map<String, dynamic>.from(res);
    } catch (e) {
      debugPrint('getNativePermissions failed: $e');
    }
    return null;
  }

  Future<void> _handlePermissions() async {
    if (mounted) setState(() => _isChecking = true);

    if (Platform.isIOS) {
      // 1) Native snapshot before
      final nativeBefore = await _getNativePermissionStatus();
      debugPrint('Native perms before: $nativeBefore');

      // 2) Dart-level request (may show system prompts)
      final statuses = await [Permission.bluetooth, Permission.locationWhenInUse].request();
      statuses.forEach((k, v) => debugPrint('Requested $k -> $v'));

      // 3) Re-check native
      var nativeAfter = await _getNativePermissionStatus();
      debugPrint('Native perms after: $nativeAfter');

      // 4) If still not determined/denied for bluetooth -> call native requestBluetooth which triggers CBCentralManager scan
      final btRaw = nativeAfter?['bluetooth']?.toString() ?? '';
      if (btRaw.toLowerCase().contains('rawvalue: 0') ||
          btRaw.toLowerCase().contains('notdetermined')) {
        try {
          await _nativeChannel.invokeMethod('requestBluetooth');
          await Future.delayed(const Duration(seconds: 1));
        } catch (e) {
          debugPrint('requestBluetooth native failed: $e');
        }
      }

      // 5) If location still not determined -> request native
      final locRaw = nativeAfter?['location']?.toString() ?? '';
      if (locRaw.toLowerCase().contains('rawvalue: 0') ||
          locRaw.toLowerCase().contains('notdetermined')) {
        try {
          await _nativeChannel.invokeMethod('requestLocationPermission');
          await Future.delayed(const Duration(seconds: 1));
        } catch (e) {
          debugPrint('requestLocationPermission native failed: $e');
        }
      }

      // 6) Trigger local network prompt (short advertise) as extra step
      try {
        await _nativeChannel.invokeMethod('triggerLocalNetwork', {'displayName': 'iOS Device'});
        await Future.delayed(const Duration(milliseconds: 900));
      } catch (e) {
        debugPrint('triggerLocalNetwork failed: $e');
      }

      // 7) Final check
      final finalNative = await _getNativePermissionStatus();
      debugPrint('Native perms final: $finalNative');

      final cb = finalNative?['bluetooth']?.toString() ?? '';
      final loc = finalNative?['location']?.toString() ?? '';

      final bluetoothOk = cb.contains('rawValue: 3') || cb.toLowerCase().contains('authorized');
      final locationOk = !loc.toLowerCase().contains('rawvalue: 0') &&
          !loc.toLowerCase().contains('notdetermined') &&
          !loc.toLowerCase().contains('denied');

      if (bluetoothOk && locationOk) {
        _goHome();
        return;
      } else {
        // Show instruction dialog and let user open settings
        if (!mounted) return;
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('İzinler Gerekli'),
            content: const Text(
              'Uygulama için Bluetooth ve Konum izinleri gerekiyor. Lütfen Ayarlar → Uygulamalar → P2P Data Transfer üzerinden izinleri verin.\n\n'
              'Eğer izinler açık görünmesine rağmen uygulama hâlâ izin istemiyorsa: Settings → General → Transfer or Reset iPhone → Reset → Reset Location & Privacy adımlarını deneyin.'
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Tamam')),
              TextButton(onPressed: () { openAppSettings(); Navigator.of(context).pop(); }, child: const Text('Ayarlar')),
            ],
          ),
        );
        if (mounted) setState(() => _isChecking = false);
        return;
      }
    } else if (Platform.isAndroid) {
      final List<Permission> perms = [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ];
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 33) {
        perms.add(Permission.nearbyWifiDevices);
      }
      final statuses = await perms.request();
      final allGranted = statuses.values.every((s) => s.isGranted);
      if (allGranted) {
        _goHome();
      } else {
        if (mounted) setState(() => _isChecking = false);
      }
    } else {
      // Other platforms — proceed
      _goHome();
    }
  }

  void _goHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: _isChecking
              ? const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 20),
                    Text('İzinler kontrol ediliyor...'),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.shield_outlined, color: Colors.amber, size: 60),
                    const SizedBox(height: 20),
                    const Text('İzinler Gerekli', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    const Text(
                      'Yakındaki cihazları bulmak için Konum, Wi-Fi ve Bluetooth izinlerini vermeniz gereklidir.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(onPressed: _handlePermissions, child: const Text('İzinleri Tekrar Dene')),
                    TextButton(onPressed: openAppSettings, child: const Text('Ayarları Manuel Olarak Aç')),
                  ],
                ),
        ),
      ),
    );
  }
}


// ----------------- HomePage (kısa, multipeer UI) -----------------
class Peer {
  final String id;
  final String name;
  Peer({required this.id, required this.name});
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Peer> discoveredPeers = [];
  List<String> connectedPeerIds = [];
  bool _isAdvertising = false;
  bool _isBrowsing = false;
  final TextEditingController _messageController = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  late String _localId;
  late String _localName;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _localId = await _getOrCreateDeviceId();
    _localName = 'Device-${_localId.substring(0, 6)}';
    await MeshService().init(deviceId: _localId, deviceName: _localName);
    _eventSub = MultipeerService.events.listen(_handleEvent, onError: (e) => debugPrint('event error: $e'));
  }

  Future<String> _getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'mesh_device_id';
    var id = prefs.getString(key);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(key, id);
    }
    return id;
  }

  void _handleEvent(Map<String, dynamic> evt) {
    final type = evt['event'] as String? ?? '';
    switch (type) {
      case 'peerFound':
        final id = evt['peerId'] as String? ?? '';
        final name = evt['displayName'] as String? ?? id;
        if (!discoveredPeers.any((p) => p.id == id)) {
          setState(() => discoveredPeers.add(Peer(id: id, name: name)));
        }
        break;
      case 'peerLost':
        final id = evt['peerId'] as String? ?? '';
        setState(() => discoveredPeers.removeWhere((p) => p.id == id));
        break;
      case 'connectionState':
        final id = evt['peerId'] as String? ?? '';
        final state = evt['state'] as String? ?? '';
        if (state == 'connected') {
          if (!connectedPeerIds.contains(id)) setState(() => connectedPeerIds.add(id));
        } else {
          setState(() => connectedPeerIds.remove(id));
        }
        break;
      case 'dataReceived':
        final data = evt['data'] as List<dynamic>?;
        final from = evt['peerId'] as String? ?? 'unknown';
        if (data != null) {
          final msg = String.fromCharCodes(data.cast<int>());
          _showStatus('Gelen: $msg (from ...${from.substring(max(0, from.length - 4))})');
        }
        break;
      case 'advertisingStarted':
        setState(() => _isAdvertising = true);
        break;
      case 'browsingStarted':
        setState(() => _isBrowsing = true);
        break;
      case 'stopped':
        setState(() {
          _isAdvertising = false;
          _isBrowsing = false;
          discoveredPeers.clear();
          connectedPeerIds.clear();
        });
        break;
      case 'error':
        final msg = evt['message'] as String? ?? 'Hata';
        _showStatus('Hata: $msg');
        break;
    }
  }

  Future<void> _startAdvertising() async {
    if (_isBrowsing) {
      _showStatus('Önce taramayı durdurun.');
      return;
    }
    if (_isAdvertising) return;
    setState(() => _isAdvertising = true);
    try {
      await MultipeerService.startAdvertising(displayName: _localName);
    } catch (e) {
      setState(() => _isAdvertising = false);
      _showStatus('Advertise error: $e');
    }
  }

  Future<void> _startBrowsing() async {
    if (_isAdvertising) {
      _showStatus('Önce reklamı durdurun.');
      return;
    }
    if (_isBrowsing) return;
    setState(() => _isBrowsing = true);
    try {
      await MultipeerService.startBrowsing();
    } catch (e) {
      setState(() => _isBrowsing = false);
      _showStatus('Browsing error: $e');
    }
  }

  void _invitePeer(Peer peer) {
    MultipeerService.invitePeer(peer.id);
    _showStatus('Davet gönderildi: ${peer.name}');
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    try {
      await MultipeerService.sendData(Uint8List.fromList(text.codeUnits));
      _messageController.clear();
      _showStatus('Gönderildi');
    } catch (e) {
      _showStatus('Gönderme hatası: $e');
    }
  }

  void _showStatus(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _messageController.dispose();
    MultipeerService.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('P2P Mesajlaşma'),
        actions: [
          if (connectedPeerIds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.link_off),
              onPressed: () => MultipeerService.stop(),
              tooltip: 'Tüm Bağlantıları Kes',
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8.0,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: (_isAdvertising || _isBrowsing) ? null : _startAdvertising,
                  icon: const Icon(Icons.wifi_tethering),
                  label: const Text('Görünür Ol (Host)'),
                ),
                ElevatedButton.icon(
                  onPressed: (_isAdvertising || _isBrowsing) ? null : _startBrowsing,
                  icon: const Icon(Icons.search),
                  label: const Text('Cihaz Ara (Guest)'),
                ),
                ElevatedButton.icon(
                  onPressed: (!_isAdvertising && !_isBrowsing) ? null : () => MultipeerService.stop(),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Durdur & Sıfırla'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(_isAdvertising ? 'DURUM: Görünürsün' : _isBrowsing ? 'DURUM: Taramada' : 'DURUM: Rol seçin',
                textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
            const Divider(height: 28),
            Expanded(
              child: ListView.builder(
                itemCount: discoveredPeers.length,
                itemBuilder: (context, index) {
                  final peer = discoveredPeers[index];
                  return Card(
                    child: ListTile(
                      title: Text(peer.name),
                      subtitle: Text(peer.id),
                      trailing: (_isBrowsing && connectedPeerIds.isEmpty)
                          ? ElevatedButton(onPressed: () => _invitePeer(peer), child: const Text('Bağlan'))
                          : null,
                    ),
                  );
                },
              ),
            ),
            if (connectedPeerIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Row(
                  children: [
                    Expanded(child: TextField(controller: _messageController, decoration: const InputDecoration(labelText: 'Herkese mesaj gönder'))),
                    const SizedBox(width: 8),
                    IconButton.filled(icon: const Icon(Icons.send), onPressed: _sendMessage, tooltip: 'Gönder'),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
