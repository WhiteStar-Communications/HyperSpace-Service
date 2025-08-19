//
//  TunnelDataBridge.swift
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/19/25.
//

// TunnelDataBridge.swift
import Foundation

import Foundation

@objc public protocol TunnelDataBridgeSink: AnyObject {
    func tunnelBridgeDidReceivePacket(_ packet: NSData)
}

@objcMembers
public final class TunnelDataBridge: NSObject, DataPlaneClientDelegate {
    public weak var sink: TunnelDataBridgeSink?

    private let client: DataPlaneClient
    private let queue: DispatchQueue

    public override init() {
        self.queue = DispatchQueue(label: "hyperspace.bridge.queue", qos: .utility)
        self.client = DataPlaneClient(host: "127.0.0.1", port: 5501, queue: queue)
        super.init()
        self.client.delegate = self
    }

    public func start() { client.start() }
    public func stop()  { client.stop()  }

    public func sendPacketToHost(_ packet: NSData) {
        client.sendPacket(packet as Data)
    }

    public func sendPacketsToHost(_ packets: [NSData]) {
        guard !packets.isEmpty else { return }
        client.sendPackets(packets.map { $0 as Data })
    }

    // MARK: DataPlaneClientDelegate
    public func dataClientDidConnect(_ client: DataPlaneClient) {}
    public func dataClient(_ client: DataPlaneClient, didDisconnect error: Error?) {}
    public func dataClient(_ client: DataPlaneClient, didReceivePacket packet: Data) {
        sink?.tunnelBridgeDidReceivePacket(packet as NSData)
    }
}
