//
//  PacketTunnelProvider.swift
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/14/25.
//

import Foundation
import NetworkExtension
import OSLog

// If you added the bridging header (recommended), Swift will see TunInterfaceRef.
// In your System Extension target's Build Settings, set "Objective-C Bridging Header"
// to a header that imports: #import "TunInterfaceBridge.h"
final class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - Optional libevent TUN path
    private var tunRef: TunInterfaceRef?  // from TunInterfaceBridge.h

    // MARK: - Fallback Swift path (packetFlow <-> DataPlaneClient)
    private var dataClient: DataPlaneClient?
    private let dataQueue = DispatchQueue(label: "hyperspace.data.client")

    // Routing state the controller can change via handleAppMessage
    private var includedRoutes = Set<String>()
    private var excludedRoutes = Set<String>()

    // Interface & DNS defaults (overridden by options)
    private var myIPv4Address = "10.0.0.2"
    private var subnetMask = "255.255.255.0"
    private let mtu: NSNumber = 1400
    private let dnsServers = ["1.1.1.1"]

    override func startTunnel(options: [String : NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {

        // Options from host app CommandServer → HyperSpaceController.start(...)
        if let ip = options?["myIPv4Address"] as? String, !ip.isEmpty {
            myIPv4Address = ip
        }
        if let inc = options?["included"] as? [String] { includedRoutes = Set(inc) }
        if let exc = options?["excluded"] as? [String] { excludedRoutes = Set(exc) }

        // Build network settings
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "hyper.space")
        let ipv4 = NEIPv4Settings(addresses: [myIPv4Address], subnetMasks: [subnetMask])
        ipv4.includedRoutes = makeIPv4Routes(from: includedRoutes)
        ipv4.excludedRoutes = makeIPv4Routes(from: excludedRoutes)
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        settings.mtu = mtu

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { completionHandler(error); return }
            guard error == nil else { completionHandler(error); return }

            // Try to use your libevent + TUN fd path if you can provide an fd:
            if let fd = self.obtainTunFileDescriptor() {
                // has_proto_header: pass 1 if your fd expects 4-byte AF_* header (utun), else 0
//                self.tunRef = TunInterfaceCreate(fd, 1)
//                if let tunRef = self.tunRef {
//                    TunInterfaceSetMTU(tunRef, Int32(truncating: self.mtu))
//                    TunInterfaceStart(tunRef)
//                    os_log("TunInterface started (fd=%d)", fd)
//                    // NOTE: In libevent mode, DataPlaneClient is created internally by TunnelIOBridge.
//                } else {
//                    os_log("TunInterfaceCreate failed; falling back to packetFlow.")
//                    self.startSwiftFallback()
//                }
            } else {
                // Fallback: Swift pump using packetFlow + DataPlaneClient
                self.startSwiftFallback()
            }

            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        if let r = tunRef {
            //TunInterfaceStop(r)
            //TunInterfaceDestroy(r)
            tunRef = nil
        }
        dataClient?.stop()
        dataClient = nil
        completionHandler()
    }

    // MARK: - Control plane from the host app

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)? = nil) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
            let cmd = obj["cmd"] as? String
        else {
            completionHandler?(encJSON(["ok": false, "error": "bad payload"]))
            return
        }

        func ok(_ payload: [String: Any] = [:]) { completionHandler?(encJSON(["ok": true, "data": payload])) }
        func fail(_ msg: String) { completionHandler?(encJSON(["ok": false, "error": msg])) }

        switch cmd {
        case "addRoute":
            guard let route = obj["route"] as? String, !route.isEmpty else { return fail("missing route") }
            includedRoutes.insert(route)
            reapplyIPv4Settings()
            ok(["added": route])

        case "removeRoute":
            guard let route = obj["route"] as? String, !route.isEmpty else { return fail("missing route") }
            includedRoutes.remove(route); excludedRoutes.remove(route)
            reapplyIPv4Settings()
            ok(["removed": route])

        case "addRoutes":
            if let routes = obj["routes"] as? [String] {
                for r in routes where !r.isEmpty { includedRoutes.insert(r) }
                reapplyIPv4Settings()
                ok(["addedCount": routes.count])
            } else { fail("missing routes[]") }

        case "removeRoutes":
            if let routes = obj["routes"] as? [String] {
                for r in routes { includedRoutes.remove(r); excludedRoutes.remove(r) }
                reapplyIPv4Settings()
                ok(["removedCount": routes.count])
            } else { fail("missing routes[]") }

        default:
            fail("unknown cmd \(cmd)")
        }
    }

    // MARK: - Swift fallback datapath (if no libevent fd)

    private func startSwiftFallback() {
        let client = DataPlaneClient(host: "127.0.0.1", port: 5501, queue: dataQueue)
        client.delegate = self
        client.start()
        dataClient = client

        // pump NE → host
        readFromTunAndForward()
    }

    private func readFromTunAndForward() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            if let cli = self.dataClient, !packets.isEmpty {
                cli.sendPackets(packets) // frames + sends to DataServer
            }
            self.readFromTunAndForward()
        }
    }

    // MARK: - Reapply routes

    private func reapplyIPv4Settings() {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "hyper.space")
        let ipv4 = NEIPv4Settings(addresses: [myIPv4Address], subnetMasks: [subnetMask])
        ipv4.includedRoutes = makeIPv4Routes(from: includedRoutes)
        ipv4.excludedRoutes = makeIPv4Routes(from: excludedRoutes)
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        settings.mtu = mtu

        setTunnelNetworkSettings(settings) { error in
            if let error { os_log("reapplyIPv4Settings error: %{public}@", error.localizedDescription) }
        }
    }

    // MARK: - Helpers

    private func makeIPv4Routes(from set: Set<String>) -> [NEIPv4Route]? {
        let out: [NEIPv4Route] = set.compactMap { spec in
            if let slash = spec.firstIndex(of: "/") {
                let base = String(spec[..<slash])
                let cidrStr = String(spec[spec.index(after: slash)...])
                guard let cidr = Int(cidrStr), (0...32).contains(cidr),
                      let mask = dottedMask(fromCIDR: cidr) else { return nil }
                return NEIPv4Route(destinationAddress: base, subnetMask: mask)
            } else {
                // single host
                return NEIPv4Route(destinationAddress: spec, subnetMask: "255.255.255.255")
            }
        }
        return out.isEmpty ? nil : out
    }

    private func dottedMask(fromCIDR cidr: Int) -> String? {
        guard (0...32).contains(cidr) else { return nil }
        let mask = cidr == 0 ? 0 : ~UInt32(0) << (32 - cidr)
        return "\((mask >> 24) & 0xff).\((mask >> 16) & 0xff).\((mask >> 8) & 0xff).\(mask & 0xff)"
    }

    private func encJSON(_ obj: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj)
    }

    /// TODO: Provide your own way to obtain the TUN fd (if you’re using one).
    /// Return nil to fall back to packetFlow.
    private func obtainTunFileDescriptor() -> Int32? {
        // Return your valid utun/TUN file descriptor here.
        return nil
    }
}

// MARK: - DataPlaneClientDelegate (fallback mode)
extension PacketTunnelProvider: DataPlaneClientDelegate {
    func dataClientDidConnect(_ client: DataPlaneClient) {
        os_log("DataServer connected")
    }
    func dataClient(_ client: DataPlaneClient, didDisconnect error: Error?) {
        os_log("DataServer disconnected: %{public}@", error?.localizedDescription ?? "nil")
    }
    // Host → TUN injection in fallback mode
    func dataClient(_ client: DataPlaneClient, didReceivePacket packet: Data) {
        packetFlow.writePackets([packet], withProtocols: [AF_INET as NSNumber])
    }
}
