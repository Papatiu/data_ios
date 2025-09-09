import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
  var multipeer: MultipeerManager?
  var eventSink: FlutterEventSink?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController

    let methodChannel = FlutterMethodChannel(name: "com.example.multipeer/methods", binaryMessenger: controller.binaryMessenger)
    let eventChannel = FlutterEventChannel(name: "com.example.multipeer/events", binaryMessenger: controller.binaryMessenger)

    eventChannel.setStreamHandler(self)

    methodChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      let args = call.arguments as? [String:Any]
      switch call.method {
        case "startAdvertising":
          let display = args?["displayName"] as? String ?? UIDevice.current.name
          let service = args?["serviceType"] as? String ?? "mpconn"
          self.multipeer = MultipeerManager(displayName: display, serviceType: service)
          self.multipeer?.setEventSink({ [weak self] evt in
            self?.eventSink?(evt)
          })
          self.multipeer?.startAdvertising()
          result(nil)
        case "startBrowsing":
          let display = args?["displayName"] as? String ?? UIDevice.current.name
          let service = args?["serviceType"] as? String ?? "mpconn"
          self.multipeer = MultipeerManager(displayName: display, serviceType: service)
          self.multipeer?.setEventSink({ [weak self] evt in
            self?.eventSink?(evt)
          })
          self.multipeer?.startBrowsing()
          result(nil)
        case "stop":
          self.multipeer?.stop()
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
        default:
          result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }



  // FlutterStreamHandler
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }
}
