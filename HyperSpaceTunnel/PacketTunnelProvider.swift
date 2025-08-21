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
                                  DataClientDelegate,
                                  TUNInterfaceBridgeDelegate {
    
    private var bridge: TUNInterfaceBridge?
    private var dataClient: DataClient?

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

            let b = TUNInterfaceBridge(tunFD: tunFD)
            b.delegate = self
            b.start()
            self.bridge = b

            let dc = DataClient(host: "127.0.0.1",
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
    func dataClientDidConnect(_ c: DataClient) {
        // do nothing for now
    }
    
    func dataClientDidDisconnect(_ c: DataClient,
                                      error: Error?) {
        // do nothing for now
    }

    func dataClient(_ c: DataClient,
                         didReceivePacket data: Data) {
        // Write into TUN via your Bridge/C++
        bridge?.writePacket(toTun: data)
    }

    func dataClient(_ c: DataClient,
                         didReceivePackets packets: [Data]) {
        for p in packets { bridge?.writePacket(toTun: p) }
    }
    
    func bridgeDidReadOutboundPacket(_ packet: Data) {
        // Send a packet outbounds
        dataClient?.sendOutgoingPacket(packet)
    }
}
