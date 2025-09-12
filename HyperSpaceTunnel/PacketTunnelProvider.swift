//
//  PacketTunnelProvider.swift
//  Created by Logan Miller on 8/14/25.
//
//  Copyright (c) 2025, WhiteStar Communications, Inc.
//  All rights reserved.
//  Licensed under the BSD 2-Clause License.
//  See LICENSE file in the project root for details.
//

import Foundation
import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider,
                                  TUNInterfaceBridgeDelegate {
    private let tunnelInfoAdapter = TUNInfoAdapter()
    private var tunnelEventClient: TunnelEventClient?
    private var bridge: TUNInterfaceBridge?
    private var dataServer: DataServer?
    
    private var myIPv4Address: String = ""
    private var includedRoutes: [String] = []
    private var excludedRoutes: [String] = []
    private var dnsMatches: [String] = []
    private var dnsMap: [String: [String]] = [:]

    override func startTunnel(options: [String : NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        guard let myIPv4Address = options?["myIPv4Address"] as? String, !myIPv4Address.isEmpty else {
            os_log("Failed to get a valid value for myIPv4Address")
            completionHandler(nil)
            return
        }
        self.myIPv4Address = myIPv4Address
        if let included = options?["includedRoutes"] as? [String], !included.isEmpty { includedRoutes = included }
        if let excluded = options?["excludedRoutes"] as? [String], !excluded.isEmpty { excludedRoutes = excluded }
        if let matches  = options?["dnsMatches"]  as? [String], !matches.isEmpty  { dnsMatches  = matches }
        if let map = options?["dnsMap"] as? [String:[String]], !map.isEmpty { dnsMap = map }

        let tunnelSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: myIPv4Address)
        tunnelSettings.mtu = NSNumber(value: (64 * 1024) - 1)

        let ipv4 = NEIPv4Settings(addresses: [myIPv4Address], subnetMasks: ["255.255.255.255"])
        let includedIPv4Routes = getIncludedIPv4Routes()
        ipv4.includedRoutes = includedIPv4Routes
        ipv4.excludedRoutes = getExcludedIPv4Routes()
        tunnelSettings.ipv4Settings = ipv4

        let dnsSettings = NEDNSSettings(servers: [myIPv4Address])
        dnsSettings.matchDomains = dnsMatches
        dnsSettings.matchDomainsNoSearch = true
        tunnelSettings.dnsSettings = dnsSettings

        guard let tunFD = tunnelInfoAdapter.tunFD else {
            os_log("Failed to get the tunnel file descriptor")
            completionHandler(nil)
            return
        }
        let b = TUNInterfaceBridge(tunFD: tunFD)
        b.delegate = self
        b.start()
        self.bridge = b

        let ds = DataServer(port: 5501,
                            bridge: bridge)
        ds?.start()
        self.dataServer = ds

        tunnelEventClient = TunnelEventClient(port: 5600)
        tunnelEventClient?.start()
        
        if !includedIPv4Routes.isEmpty {
            for r in includedIPv4Routes {
                if let range = try? getAddressRange(in: r) {
                    bridge?.addKnownIPAddresses(range)
                }
            }
        }
        if !dnsMap.isEmpty {
            bridge?.setDNSMap(dnsMap)
        }

        setTunnelNetworkSettings(tunnelSettings) { err in
            if let err { os_log("An error occurred applying tunnelSettings: %{public}@", String(describing: err)) }
            completionHandler(err)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        bridge?.stop()
        bridge = nil
        dataServer?.stop()
        dataServer = nil

        tunnelEventClient?.sendSync([
            "event": "tunnelStopped",
            "reason": deriveNEProviderStopReason(code: reason.rawValue)
        ], timeout: 0.5)

        tunnelEventClient?.stop()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)? = nil) {
        guard let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let command = obj["command"] as? String else {
            completionHandler?(encJSON(["ok": false, "error": "bad payload"]))
            return
        }

        func ok(_ payload: [String: Any] = [:]) { completionHandler?(encJSON(["ok": true, "data": payload])) }
        func fail(_ msg: String) { completionHandler?(encJSON(["ok": false, "error": msg])) }

        switch command {
        case "update":
            if let included = obj["includedRoutes"] as? [String], Set(included) != Set(includedRoutes) {
                includedRoutes = included
                os_log("Received includedRoutes: %{public}@", included.joined(separator: ", "))
            }
            if let excluded = obj["excludedRoutes"] as? [String], Set(excluded) != Set(excludedRoutes) {
                excludedRoutes = excluded
                os_log("Received excludedRoutes: %{public}@", excluded.joined(separator: ", "))
            }
            if let matches = obj["dnsMatches"] as? [String], Set(matches) != Set(dnsMatches) {
                dnsMatches = matches
                os_log("Received dnsMatches: %{public}@", matches.joined(separator: ", "))
            }
            if let map = obj["dnsMap"] as? [String: [String]], map != dnsMap {
                dnsMap = map
                let desc = map.map { "\($0): [\($1.joined(separator: ", "))]" }.joined(separator: "; ")
                os_log("Received dnsMap: %{public}@", desc)
            }
            reapplyIPv4Settings() { error in if error != nil { fail("Failed to apply tunnel settings: \(String(describing: error))") } }
            ok(["updated": true])

        default:
            fail("unknown cmd \(command)")
        }
    }

    func bridgeDidReadOutboundPacket(_ packet: Data) {
        dataServer?.sendPacketsToExternalApp([UInt8](packet))
    }

    private func encJSON(_ obj: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj)
    }

    private func reapplyIPv4Settings(completionHandler: @escaping (Error?) -> Void) {
        let tunnelSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: myIPv4Address)
        tunnelSettings.mtu = NSNumber(value: (64 * 1024) - 1)

        let ipv4Settings = NEIPv4Settings(addresses: [myIPv4Address], subnetMasks: ["255.255.255.255"])
        let includedIPv4Routes = getIncludedIPv4Routes()
        ipv4Settings.includedRoutes = includedIPv4Routes
        ipv4Settings.excludedRoutes = getExcludedIPv4Routes()
        tunnelSettings.ipv4Settings = ipv4Settings

        let dnsSettings = NEDNSSettings(servers: [myIPv4Address])
        dnsSettings.matchDomains = dnsMatches
        dnsSettings.matchDomainsNoSearch = true
        tunnelSettings.dnsSettings = dnsSettings

        if !includedIPv4Routes.isEmpty {
            for r in includedIPv4Routes {
                if let range = try? getAddressRange(in: r) { bridge?.addKnownIPAddresses(range) }
            }
        }
        if !dnsMap.isEmpty {
            bridge?.addAllAbsentDNSEntries(dnsMap)
        }

        setTunnelNetworkSettings(tunnelSettings) { error in
            if let error = error { os_log("Failed to apply tunnel settings: %{public}@", String(describing: error)) }
            completionHandler(error)
        }
    }

    func deriveNEProviderStopReason(code: Int) -> String {
        switch code {
        case 0:  return "No specific reason has been given."
        case 1:  return "The user stopped the tunnel."
        case 2:  return "The tunnel failed to function correctly."
        case 3:  return "No network connectivity is currently available."
        case 4:  return "The device’s network connectivity changed."
        case 5:  return "The provider was disabled."
        case 6:  return "The authentication process was canceled."
        case 7:  return "The configuration is invalid."
        case 8:  return "The session timed out."
        case 9:  return "The configuration was disabled."
        case 10: return "The configuration was removed."
        case 11: return "Superseded by a higher-priority configuration."
        case 12: return "The user logged out."
        case 13: return "The current console user changed."
        case 14: return "The connection failed."
        default: return "Unknown reason."
        }
    }

    enum IPAddressConversionError: Error, LocalizedError {
        case invalidIP(String)
        case unsupportedMask(String)
        case tooManyAddresses(Int)
        var errorDescription: String? {
            switch self {
            case .invalidIP(let s):        return "Invalid IPv4 address: \(s)"
            case .unsupportedMask(let s):  return "Unsupported subnet mask: \(s)"
            case .tooManyAddresses(let n): return "Route expands to \(n) addresses."
            }
        }
    }

    public func getIncludedIPv4Routes() -> [NEIPv4Route] {
        var result: [NEIPv4Route] = []
        for route in includedRoutes {
            if let ipv4Route = convertToIPv4Route(string: route) {
                result.append(ipv4Route)
            }
        }
        return result
    }

    public func getExcludedIPv4Routes() -> [NEIPv4Route] {
        var result: [NEIPv4Route] = []
        for route in excludedRoutes {
            if let ipv4Route = convertToIPv4Route(string: route) {
                result.append(ipv4Route)
            }
        }
        return result
    }

    public func convertToIPv4Route(string: String) -> NEIPv4Route? {
        if string.contains("/") {
            let components = string.split(separator: "/")
            guard components.count == 2,
                  let prefixLength = Int(components[1]),
                  prefixLength >= 0 && prefixLength <= 32 else { return nil }
            let ipAddress = String(components[0])
            guard let subnetMask = subnetMaskFromPrefixLength(prefixLength) else { return nil }
            return NEIPv4Route(destinationAddress: ipAddress, subnetMask: subnetMask)
        } else {
            return NEIPv4Route(destinationAddress: string, subnetMask: "255.255.255.255")
        }
    }

    public func subnetMaskFromPrefixLength(_ prefix: Int) -> String? {
        guard prefix >= 0 && prefix <= 32 else { return nil }
        let mask = UInt32.max << (32 - prefix)
        let octets = [(mask >> 24) & 0xFF, (mask >> 16) & 0xFF, (mask >> 8) & 0xFF, (mask >> 0) & 0xFF]
        return octets.map { String($0) }.joined(separator: ".")
    }

    private func ipv4ToUInt32(_ s: String) throws -> UInt32 {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { throw IPAddressConversionError.invalidIP(s) }
        var v: UInt32 = 0
        for p in parts {
            guard let oct = UInt8(p) else { throw IPAddressConversionError.invalidIP(s) }
            v = (v << 8) | UInt32(oct)
        }
        return v
    }

    private func uInt32ToIPv4(_ v: UInt32) -> String {
        return "\( (v >> 24) & 0xFF ).\( (v >> 16) & 0xFF ).\( (v >> 8) & 0xFF ).\( v & 0xFF )"
    }

    private func maskToPrefix(_ mask: String) throws -> Int {
        switch mask {
        case "0.0.0.0": return 0
        case "255.0.0.0": return 8
        case "255.255.0.0": return 16
        case "255.255.255.0": return 24
        case "255.255.255.255": return 32
        default: throw IPAddressConversionError.unsupportedMask(mask)
        }
    }

    func getAddressRange(in route: NEIPv4Route, cap: Int? = 1_000_000) throws -> [String] {
        let dest = try ipv4ToUInt32(route.destinationAddress)
        let prefix = try maskToPrefix(route.destinationSubnetMask)
        let hostBits = 32 - prefix
        let total = prefix == 32 ? 1 : (1 << hostBits)
        if let c = cap, total > c { throw IPAddressConversionError.tooManyAddresses(total) }
        if prefix == 32 { return [route.destinationAddress] }

        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32((1 << hostBits) - 1)
        let network = dest & mask
        let broadcast = network | ~mask

        var out: [String] = []
        var cur = network
        let end = broadcast - 1
        while cur <= end {
            out.append(uInt32ToIPv4(cur))
            cur &+= 1
        }
        return out
    }
}
