import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
// Gerekli importlar
import 'multipeer_service.dart';
import 'mesh/mesh_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:device_info_plus/device_info_plus.dart'; // Versiyon kontrolü için
import 'dart:io';
import 'dart:typed_data'; // Uint8List için

void main() {
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
  // build metodu UI için olduğu için bu değişkeni ekledim.
  bool _isChecking = true;

  @override
  void initState() {
    super.initState();
    _handlePermissions();
  }

  Future<void> _handlePermissions() async {
    // UI'ı "kontrol ediliyor..." durumuna al.
    if (mounted) setState(() => _isChecking = true);

    // Her platform için doğru izin listesini oluştur.
    List<Permission> permissionsToRequest = [];
    if (Platform.isAndroid) {
      permissionsToRequest.addAll([
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ]);
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 33) {
        permissionsToRequest.add(Permission.nearbyWifiDevices);
      }
    } else if (Platform.isIOS) {
      permissionsToRequest.addAll([
        Permission.bluetooth, // iOS için bu tek izin yeterli.
        // Konum izni, paketin kendisi tarafından istenmese de en iyi pratikler arasındadır.
        Permission.locationWhenInUse,
      ]);
    }

    // Gerekli izinleri iste.
    Map<Permission, PermissionStatus> statuses = await permissionsToRequest
        .request();

    // İzinlerin tamamının verilip verilmediğini kontrol et.
    bool allGranted = true;
    statuses.forEach((permission, status) {
      if (!status.isGranted) {
        print("İzin Reddedildi: $permission -> $status");
        allGranted = false;
      }
    });

    if (!mounted) return;

    if (allGranted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const HomePage()),
      );
    } else {
      // Eğer izinler verilmediyse, UI'ın "izin gerekli" ekranını göstermesi için güncelle.
      setState(() => _isChecking = false);
    }
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
                    const Icon(
                      Icons.shield_outlined,
                      color: Colors.amber,
                      size: 60,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'İzinler Gerekli',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Yakındaki cihazları bulmak için Konum, Wi-Fi ve Bluetooth izinlerini vermeniz zorunludur.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _handlePermissions,
                      child: const Text('İzinleri Tekrar Dene'),
                    ),
                    TextButton(
                      onPressed: openAppSettings,
                      child: const Text('Ayarları Manuel Olarak Aç'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

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
  List<String> connectedPeerIds = [];
  List<Peer> discoveredPeers = [];
  final TextEditingController _messageController = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  late String _localId;
  late String _localName;
  bool _initializing = true;
  bool _isAdvertising = false;
  bool _isBrowsing = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _messageController.dispose();
    MultipeerService.stop();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    _localId = await _getOrCreateDeviceId();
    _localName = 'Device-${_localId.substring(0, 6)}';
    // MeshService'in artık tek görevi bize kalıcı bir ID vermek.
    await MeshService().init(deviceId: _localId, deviceName: _localName);
    _startListening();
    setState(() => _initializing = false);
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

  void _startListening() {
    _eventSub = MultipeerService.events.listen((evt) {
      if (!mounted) return;
      final type = evt['event'] as String? ?? '';
      switch (type) {
        case 'peerFound':
          setState(() {
            if (!discoveredPeers.any(
              (p) => p.id == (evt['peerId'] as String? ?? ''),
            )) {
              discoveredPeers.add(
                Peer(id: evt['peerId'], name: evt['displayName']),
              );
            }
          });
          break;
        case 'peerLost':
          setState(
            () => discoveredPeers.removeWhere(
              (p) => p.id == (evt['peerId'] as String? ?? ''),
            ),
          );
          break;
        case 'connectionState':
          final id = evt['peerId'] as String?;
          if (id == null) return;
          setState(() {
            if (evt['state'] == 'connected') {
              if (!connectedPeerIds.contains(id)) connectedPeerIds.add(id);
            } else {
              connectedPeerIds.remove(id);
            }
          });
          break;
        case 'dataReceived': // Gelen mesajları doğrudan burada yakalıyoruz.
          final fromPeerId = evt['peerId'] as String? ?? 'Bilinmeyen';
          final data = evt['data'] as List<dynamic>?;
          if (data != null) {
            final message = String.fromCharCodes(data.cast<int>());
            _showStatus(
              '"$message" - (Gelen ID: ...${fromPeerId.substring(fromPeerId.length - 4)})',
            );
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
          _showStatus(evt['message'] as String? ?? 'Bilinmeyen Hata');
          setState(() {
            _isAdvertising = false;
            _isBrowsing = false;
          });
          break;
      }
    });
  }

  Future<void> _startAdvertising() async {
    if (_isBrowsing) {
      _showStatus('Önce Taramayı Durdurun.');
      return;
    }
    if (_isAdvertising) return;
    await MultipeerService.startAdvertising(displayName: _localName);
  }

  Future<void> _startBrowsing() async {
    if (_isAdvertising) {
      _showStatus('Önce Reklamı Durdurun.');
      return;
    }
    if (_isBrowsing) return;
    await MultipeerService.startBrowsing();
  }

  Future<void> _stopAllOperations() async {
    await MultipeerService.stop();
  }

  void _invitePeer(Peer peer) {
    MultipeerService.invitePeer(peer.id);
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final bytes = Uint8List.fromList(text.codeUnits);
    await MultipeerService.sendData(bytes);

    _messageController.clear();
    _showStatus("Mesajın gönderildi");
  }

  void _showStatus(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
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
              onPressed: _stopAllOperations,
              tooltip: 'Tüm Bağlantıları Kes',
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: _initializing
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8.0,
                    alignment: WrapAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isAdvertising || _isBrowsing
                            ? null
                            : _startAdvertising,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isAdvertising
                              ? Colors.blue.shade800
                              : Colors.blue,
                        ),
                        icon: const Icon(Icons.wifi_tethering),
                        label: const Text('Görünür Ol (Host)'),
                      ),
                      ElevatedButton.icon(
                        onPressed: _isAdvertising || _isBrowsing
                            ? null
                            : _startBrowsing,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isBrowsing
                              ? Colors.green.shade800
                              : Colors.green,
                        ),
                        icon: const Icon(Icons.search),
                        label: const Text('Cihaz Ara (Guest)'),
                      ),

                      ElevatedButton.icon(
                        onPressed: !_isAdvertising && !_isBrowsing
                            ? null
                            : _stopAllOperations,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('Durdur & Sıfırla'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _isAdvertising
                        ? "DURUM: Diğer cihazlar tarafından görünürsün."
                        : _isBrowsing
                        ? "DURUM: Yakındaki cihazlar taranıyor..."
                        : "DURUM: Başlamak için bir rol seçin.",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    connectedPeerIds.isNotEmpty
                        ? 'BAĞLANDI (${connectedPeerIds.length} cihaz)'
                        : 'BAĞLANTI YOK',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: connectedPeerIds.isNotEmpty
                          ? Colors.green
                          : Colors.grey,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const Divider(height: 30),
                  if (_isBrowsing && connectedPeerIds.isEmpty)
                    const Text(
                      'Bulunan Cihazlar',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: discoveredPeers.length,
                      itemBuilder: (context, index) {
                        final peer = discoveredPeers[index];
                        final canInvite =
                            _isBrowsing && connectedPeerIds.isEmpty;
                        final subtitleId = peer.id.length > 8
                            ? '${peer.id.substring(0, 8)}...'
                            : peer.id;
                        return Card(
                          child: ListTile(
                            title: Text(peer.name),
                            subtitle: Text('ID: $subtitleId'),
                            trailing: canInvite
                                ? ElevatedButton(
                                    onPressed: () => _invitePeer(peer),
                                    child: const Text('Bağlan'),
                                  )
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
                          Expanded(
                            child: TextField(
                              controller: _messageController,
                              decoration: const InputDecoration(
                                labelText: 'Herkese mesaj gönder',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            icon: const Icon(Icons.send),
                            onPressed: _sendMessage,
                            tooltip: 'Gönder',
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}