//
//  PacketTunnelProvider.swift
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/14/25.
//

import Foundation
import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider,
                                  DataPlaneClientDelegate,
                                  TunnelDataBridgeDelegate {
    
    private var bridge: TunnelDataBridge?
    private var dataClient: DataPlaneClient?

    override func startTunnel(options: [String : NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] err in
            guard let self else { return }
            if let err { completionHandler(err); return }

            let tunFD: Int32 = 0

            let b = TunnelDataBridge(tunFD: tunFD)
            b.delegate = self
            b.start()
            self.bridge = b

            let dc = DataPlaneClient(host: "127.0.0.1",
                                     port: 5501)
            dc.delegate = self
            dc.start()
            self.dataClient = dc

            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        dataClient?.stop()
        bridge?.stop()
        bridge = nil
        dataClient = nil

        completionHandler()
    }
    
    // MARK: DataPlaneClientDelegate
    func dataPlaneClientDidConnect(_ c: DataPlaneClient) {
        // do nothing for now
    }
    
    func dataPlaneClientDidDisconnect(_ c: DataPlaneClient,
                                      error: Error?) {
        // do nothing for now
    }

    func dataPlaneClient(_ c: DataPlaneClient,
                         didReceivePacket data: Data) {
        // Write into TUN via your Bridge/C++
        bridge?.writePacket(toTun: data)
    }

    func dataPlaneClient(_ c: DataPlaneClient,
                         didReceivePackets packets: [Data]) {
        for p in packets { bridge?.writePacket(toTun: p) }
    }
    
    func bridgeDidReadOutboundPacket(_ packet: Data) {
        // Send a packet outbounds
        dataClient?.sendPacket(packet)
    }
}
