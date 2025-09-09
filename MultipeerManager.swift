import Foundation
import MultipeerConnectivity

class MultipeerManager: NSObject {
  private var foundPeers: [String: MCPeerID] = [:]
  private var serviceType: String
  private var peerID: MCPeerID!
  private var session: MCSession!
  private var advertiser: MCNearbyServiceAdvertiser?
  private var browser: MCNearbyServiceBrowser?
  private var eventSink: ((Any) -> Void)?

  init(displayName: String = UIDevice.current.name, serviceType: String = "mpconn") {
    self.serviceType = serviceType
    super.init()
    self.peerID = MCPeerID(displayName: displayName)
    self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    self.session.delegate = self
  }

  func setEventSink(_ sink: @escaping (Any)->Void) {
    self.eventSink = sink
  }

  private func sendEvent(_ dict: [String: Any]) {
    DispatchQueue.main.async {
      self.eventSink?(dict)
    }
  }

  func startAdvertising() {
    stopAdvertising()
    let info: [String: String] = [:]
    advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: info, serviceType: serviceType)
    advertiser?.delegate = self
    advertiser?.startAdvertisingPeer()
    sendEvent(["event": "advertisingStarted"])
  }

  func startBrowsing() {
    stopBrowsing()
    browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
    browser?.delegate = self
    browser?.startBrowsingForPeers()
    sendEvent(["event": "browsingStarted"])
  }

  func stop() {
    stopAdvertising()
    stopBrowsing()
    session.disconnect()
    sendEvent(["event": "stopped"])
  }

  private func stopAdvertising() {
    advertiser?.stopAdvertisingPeer()
    advertiser = nil
  }

  private func stopBrowsing() {
    browser?.stopBrowsingForPeers()
    browser = nil
  }

  func invitePeer(byDisplayName displayName: String, timeout: TimeInterval = 30) {
  guard let peer = foundPeers[displayName] else {
    sendEvent(["event": "error", "message": "Peer not found: \(displayName)"])
    return
  }
  browser?.invitePeer(peer, to: session, withContext: nil, timeout: timeout)
  sendEvent(["event": "invitationSent", "peerId": displayName])
}

  func sendData(_ data: Data) {
    if session.connectedPeers.count > 0 {
      do {
        try session.send(data, toPeers: session.connectedPeers, with: .reliable)
      } catch {
        sendEvent(["event": "error", "message": "send error: \(error.localizedDescription)"])
      }
    } else {
      sendEvent(["event": "error", "message": "No connected peers"])
    }
  }
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension MultipeerManager: MCNearbyServiceAdvertiserDelegate {
  func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    // Otomatik kabul ediyoruz (isteğe göre Flutter tarafına gönderip onay alabilirsiniz)
    invitationHandler(true, self.session)
    sendEvent(["event": "invitationReceived", "peerId": peerID.displayName, "displayName": peerID.displayName])
  }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultipeerManager: MCNearbyServiceBrowserDelegate {
  func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
    foundPeers[peerID.displayName] = peerID
    sendEvent(["event": "peerFound", "peerId": peerID.displayName, "displayName": peerID.displayName])
  }

  func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    sendEvent(["event": "peerLost", "peerId": peerID.displayName, "displayName": peerID.displayName])
  }
}




// MARK: - MCSessionDelegate
extension MultipeerManager: MCSessionDelegate {
  func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    let stateStr: String
    switch state {
      case .connected: stateStr = "connected"
      case .connecting: stateStr = "connecting"
      case .notConnected: stateStr = "notConnected"
      @unknown default: stateStr = "unknown"
    }
    sendEvent(["event": "connectionState", "peerId": peerID.displayName, "state": stateStr])
  }

  func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
    // Gönderiyoruz: bytes olarak Flutter tarafı Uint8List alabilir
    sendEvent(["event": "dataReceived", "peerId": peerID.displayName, "data": Array(data)])
  }

  // Aşağıdakiler zorunlu ama biz basit implement yapıyoruz:
  func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
  func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
  func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}
