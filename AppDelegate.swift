import UIKit
import Flutter
import CoreBluetooth
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler, CLLocationManagerDelegate, CBCentralManagerDelegate {
  var multipeer: MultipeerManager?
  var eventSink: FlutterEventSink?
  var locationManager: CLLocationManager?
  var btRequesterManager: CBCentralManager?
  // small internal flag to avoid restarting repeated flows
  private var hasRequestedBluetoothPrompt = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return false
    }

    let methodChannel = FlutterMethodChannel(name: "com.example.multipeer/methods", binaryMessenger: controller.binaryMessenger)
    let eventChannel = FlutterEventChannel(name: "com.example.multipeer/events", binaryMessenger: controller.binaryMessenger)

    eventChannel.setStreamHandler(self)

    // Prepare a CLLocationManager to be able to requestWhenInUse and listen status changes
    self.locationManager = CLLocationManager()
    self.locationManager?.delegate = self

    methodChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any]

      switch call.method {
      case "startAdvertising":
        // stop any existing multipeer session then create new
        self.multipeer?.stop()
        let display = args?["displayName"] as? String ?? UIDevice.current.name
        let service = args?["serviceType"] as? String ?? "mpconn"
        self.multipeer = MultipeerManager(displayName: display, serviceType: service)
        self.multipeer?.setEventSink { [weak self] evt in
          self?.eventSink?(evt)
        }
        self.multipeer?.startAdvertising()
        result(nil)

      case "startBrowsing":
        self.multipeer?.stop()
        let display = args?["displayName"] as? String ?? UIDevice.current.name
        let service = args?["serviceType"] as? String ?? "mpconn"
        self.multipeer = MultipeerManager(displayName: display, serviceType: service)
        self.multipeer?.setEventSink { [weak self] evt in
          self?.eventSink?(evt)
        }
        self.multipeer?.startBrowsing()
        result(nil)

      case "stop":
        self.multipeer?.stop()
        self.multipeer = nil
        result(nil)

      case "sendData":
        if let typed = args?["data"] as? FlutterStandardTypedData {
          self.multipeer?.sendData(typed.data)
          result(nil)
        } else {
          result(FlutterError(code: "INVALID", message: "No data", details: nil))
        }

      case "invitePeer":
        if let peerId = args?["peerId"] as? String {
          self.multipeer?.invitePeer(byDisplayName: peerId)
          result(nil)
        } else {
          result(FlutterError(code: "INVALID", message: "peerId required", details: nil))
        }

      // Native prompt triggers
      case "requestBluetooth":
        // Create a temporary central manager to provoke the system permission/dialog.
        // Keep reference on AppDelegate to avoid immediate deallocation.
        // centralManager delegate method will start a short scan once poweredOn.
        if self.btRequesterManager == nil {
          self.hasRequestedBluetoothPrompt = false
          self.btRequesterManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        result(nil)

      case "requestLocationPermission":
        DispatchQueue.main.async {
          self.locationManager?.requestWhenInUseAuthorization()
        }
        result(nil)

      case "triggerLocalNetwork":
        // Quick advertise with Multipeer to provoke local network (NSLocalNetwork) prompt.
        let display = args?["displayName"] as? String ?? UIDevice.current.name
        let service = args?["serviceType"] as? String ?? "mpconn"
        let tmp = MultipeerManager(displayName: display, serviceType: service)
        tmp.setEventSink { [weak self] evt in
          self?.eventSink?(evt)
        }
        tmp.startAdvertising()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          tmp.stop()
        }
        result(nil)

      case "getNativePermissions":
        // Return stringified native statuses to Dart
        let btAuth: String
        if #available(iOS 13.1, *) {
          btAuth = String(describing: CBManager.authorization)
        } else {
          btAuth = "unavailable"
        }

        let locAuth: String
        if #available(iOS 14.0, *) {
          locAuth = String(describing: self.locationManager?.authorizationStatus ?? CLAuthorizationStatus.notDetermined)
        } else {
          locAuth = String(describing: CLLocationManager.authorizationStatus())
        }

        let info = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
        let hasBonjour = info.joined(separator: ",")
        result(["bluetooth": btAuth, "location": locAuth, "bonjour": hasBonjour])

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - CLLocationManagerDelegate
  // iOS 14+ uses locationManagerDidChangeAuthorization(_:)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    // Map to CLAuthorizationStatus for sending
    var statusStr = "unknown"
    if #available(iOS 14.0, *) {
      let st = manager.authorizationStatus
      switch st {
      case .notDetermined: statusStr = "notDetermined"
      case .restricted: statusStr = "restricted"
      case .denied: statusStr = "denied"
      case .authorizedAlways: statusStr = "authorizedAlways"
      case .authorizedWhenInUse: statusStr = "authorizedWhenInUse"
      @unknown default: statusStr = "unknown"
      }
    } else {
      let st = CLLocationManager.authorizationStatus()
      switch st {
      case .notDetermined: statusStr = "notDetermined"
      case .restricted: statusStr = "restricted"
      case .denied: statusStr = "denied"
      case .authorizedAlways: statusStr = "authorizedAlways"
      case .authorizedWhenInUse: statusStr = "authorizedWhenInUse"
      @unknown default: statusStr = "unknown"
      }
    }
    eventSink?(["event": "nativeLocationChanged", "status": statusStr])
  }

  // for backward compatibility
  func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    locationManagerDidChangeAuthorization(manager)
  }

  // MARK: - CBCentralManagerDelegate
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    // When powered on, start a short scan to trigger system permission prompt if needed.
    switch central.state {
    case .poweredOn:
      // Only attempt scan once per request to avoid repeated behavior
      if !hasRequestedBluetoothPrompt {
        hasRequestedBluetoothPrompt = true
        // Start quick scan (no service filter) to force permission evaluation
        central.scanForPeripherals(withServices: nil, options: nil)
        // stop after short time
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
          central.stopScan()
          // Release manager after a short delay so GC can collect it
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.btRequesterManager = nil
            self.hasRequestedBluetoothPrompt = false
          }
        }
      }
    default:
      break
    }
  }

  // MARK: - FlutterStreamHandler
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    // Immediately push current native permisssion snapshot (non-blocking)
    var btAuth = "unavailable"
    if #available(iOS 13.1, *) {
      btAuth = String(describing: CBManager.authorization)
    }
    var locAuth = "unknown"
    if #available(iOS 14.0, *) {
      locAuth = String(describing: self.locationManager?.authorizationStatus ?? CLAuthorizationStatus.notDetermined)
    } else {
      locAuth = String(describing: CLLocationManager.authorizationStatus())
    }
    let info = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
    let hasBonjour = info.joined(separator: ",")
    events(["event": "nativeSnapshot", "bluetooth": btAuth, "location": locAuth, "bonjour": hasBonjour])
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }
}
