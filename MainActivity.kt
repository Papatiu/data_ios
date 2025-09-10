package com.example.p2p_data_transfer

import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.Charset
import java.util.*

class MainActivity : FlutterActivity() {
    private val TAG = "P2P_Native_Android"
    private val METHOD_CHANNEL = "com.example.multipeer/methods" // Ortak kanal adı
    private val EVENT_CHANNEL = "com.example.multipeer/events" // Ortak kanal adı

    private var eventSink: EventChannel.EventSink? = null
    
    private val BLE_SERVICE_UUID: UUID = UUID.fromString("0000feed-0000-1000-8000-00805f9b34fb")
    private val BLE_SERVICE_PARCEL = ParcelUuid(BLE_SERVICE_UUID)
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var bleAdvertiser: BluetoothLeAdvertiser? = null
    private var bleAdvertiseCallback: AdvertiseCallback? = null
    private var bleScanner: BluetoothLeScanner? = null
    private var bleScannerCallback: ScanCallback? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initBleIfNeeded()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    val args = call.arguments as? Map<String, Any?>
                    when (call.method) {
                        // iOS için olanları görmezden gel
                        "startAdvertising_iOS", "stopAdvertising_iOS" -> { result.success(null) }
                        
                        // ORTAK, PLATFORM BAĞIMSIZ KOMUTLAR
                        "startAdvertising" -> {
                            val deviceId = args?.get("deviceId") as? String ?: "UnknownID"
                            val deviceName = args?.get("deviceName") as? String ?: "AndroidDevice"
                            startBleAdvertising(deviceId, deviceName)
                            result.success(null)
                        }
                        "stopAdvertising" -> {
                            stopBleAdvertising()
                            result.success(null)
                        }
                        "startScanning" -> {
                            startBleScanning()
                            result.success(null)
                        }
                        "stopScanning" -> {
                            stopBleScanning()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Method handler error", e)
                    result.error("EXCEPTION", e.message, null)
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { eventSink = events }
                override fun onCancel(arguments: Any?) { eventSink = null }
            })
    }
    
    // --- Diğer Fonksiyonlar ---
    private fun sendEvent(map: Map<String, Any?>) {
        Handler(Looper.getMainLooper()).post {
            try { eventSink?.success(map) }
            catch (e: Exception) { Log.w(TAG, "Event send failed", e) }
        }
    }

    private fun initBleIfNeeded() {
        try {
            val bm = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            bluetoothAdapter = bm.adapter
            bleAdvertiser = bluetoothAdapter?.bluetoothLeAdvertiser
            bleScanner = bluetoothAdapter?.bluetoothLeScanner
        } catch (e: Exception) { Log.w(TAG, "initBleIfNeeded failed: ${e.message}") }
    }

    private fun startBleAdvertising(deviceId: String, deviceName: String) {
        stopBleAdvertising()
        if (bleAdvertiser == null) { sendEvent(mapOf("event" to "error", "message" to "BLE advertiser not available")); return }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false).build()

        val payload = deviceName.toByteArray(Charset.forName("UTF-8"))
        val data = AdvertiseData.Builder()
            .addServiceUuid(BLE_SERVICE_PARCEL)
            .addServiceData(BLE_SERVICE_PARCEL, payload)
            .setIncludeDeviceName(true).build()

        bleAdvertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(s: AdvertiseSettings) {
                Log.d(TAG, "BLE advertise started."); sendEvent(mapOf("event" to "advertisingStarted"))
            }
            override fun onStartFailure(errorCode: Int) {
                Log.e(TAG, "BLE advertise failed: $errorCode"); sendEvent(mapOf("event" to "error", "message" to "BLE advertise failed: $errorCode"))
            }
        }
        try { bleAdvertiser?.startAdvertising(settings, data, bleAdvertiseCallback) }
        catch (e: Exception) { sendEvent(mapOf("event" to "error", "message" to "BLE reklamı başlatılamadı.")) }
    }

    private fun stopBleAdvertising() {
        try { bleAdvertiseCallback?.let { bleAdvertiser?.stopAdvertising(it) } }
        catch (e: Exception) { Log.w(TAG, "stopBleAdvertising failed", e)
        } finally { bleAdvertiseCallback = null }
    }

    private fun startBleScanning() {
        stopBleScanning()
        if (bleScanner == null) { sendEvent(mapOf("event" to "error", "message" to "LE scanner unavailable")); return }

        val filter = ScanFilter.Builder().setServiceUuid(BLE_SERVICE_PARCEL).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()

        bleScannerCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                try {
                    val device = result.device
                    val name = result.scanRecord?.getServiceData(BLE_SERVICE_PARCEL)?.toString(Charset.forName("UTF-8")) ?: device.name ?: "Bilinmeyen"
                    sendEvent(mapOf(
                        "event" to "peerFound", 
                        "peerId" to device.address,
                        "displayName" to name,
                        "rssi" to result.rssi
                    ))
                } catch (e: Exception) { Log.w(TAG, "scan result error", e) }
            }
            override fun onScanFailed(errorCode: Int) {
                sendEvent(mapOf("event" to "error", "message" to "BLE scan failed: $errorCode"))
            }
        }
        try { bleScanner?.startScan(listOf(filter), settings, bleScannerCallback); sendEvent(mapOf("event" to "bleScanningStarted")) }
        catch (e: Exception) { sendEvent(mapOf("event" to "error", "message" to "BLE tarama başlatılamadı.")) }
    }

    private fun stopBleScanning() {
        try { bleScannerCallback?.let { bleScanner?.stopScan(it) } }
        catch (e: Exception) { Log.w(TAG, "stopBleScanning failed", e)
        } finally { bleScannerCallback = null }
    }
}