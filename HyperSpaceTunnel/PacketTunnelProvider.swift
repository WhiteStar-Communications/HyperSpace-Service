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
    private var isDNSActive: Bool = false
    private var myIPv4Address: String = ""
    private var includedRoutes: [String] = []
    private var excludedRoutes: [String] = []

    override func startTunnel(options: [String : NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        guard let myIPv4Address = options?["myIPv4Address"] as? String,
              let myValidatedIPv4Address = validateIPv4HostAddress(myIPv4Address) else {
            os_log("Failed to get a valid value for myIPv4Address")
            completionHandler(nil)
            return
        }
        self.myIPv4Address = myValidatedIPv4Address

        let tunnelSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: myValidatedIPv4Address)
        tunnelSettings.mtu = NSNumber(value: (64 * 1024) - 1)

        let ipv4 = NEIPv4Settings(addresses: [myIPv4Address],
                                  subnetMasks: ["255.255.255.255"])
        tunnelSettings.ipv4Settings = ipv4

        if isDNSActive {
            let dnsSettings = NEDNSSettings(servers: [myIPv4Address])
            dnsSettings.matchDomains = [""]
            tunnelSettings.dnsSettings = dnsSettings
        } else {
            let dnsSettings = NEDNSSettings(servers: [])
            dnsSettings.matchDomains = []
            tunnelSettings.dnsSettings = dnsSettings
        }

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

        setTunnelNetworkSettings(tunnelSettings) { error in
            if let error = error {
                os_log("An error occurred starting the tunnel - %{public}@", error.localizedDescription)
                completionHandler(error)
                return
            }
                        
            completionHandler(nil)
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
              let cmd = obj["cmd"] as? String else {
            completionHandler?(encJSON(["ok": false, "error": "bad payload"]))
            return
        }
        
        func ok() {
            completionHandler?(encJSON(["ok": true]))
        }
        
        func ok(resultKey: String, resultValue: Any) {
            completionHandler?(encJSON(["ok": true, resultKey: resultValue]))
        }
        
        func fail(_ msg: String) {
            completionHandler?(encJSON(["ok": false, "error": msg]))
        }

        switch cmd {
        case "sendTunnelStarted":
            tunnelEventClient?.send([
                "event": "tunnelStarted"
            ])
            ok()
        case "getName":
            if let name = tunnelInfoAdapter.interfaceName {
                ok(resultKey: "name", resultValue: name)
                return
            }
            fail("Failed to get the interface's name")
        case "turnOnDNS":
            isDNSActive = true
            reapplyIPv4Settings() { error in
                if let error = error {
                    fail("An error occurred reapplying tunnel settings - \(error)")
                    return
                }
                ok()
            }
        case "turnOffDNS":
            isDNSActive = false
            reapplyIPv4Settings() { error in
                if let error = error {
                    fail("An error occurred reapplying tunnel settings - \(error)")
                    return
                }
                ok()
            }
        case "addIncludedRoutes":
            var shouldUpdate: Bool = false
            if let routes = obj["routes"] as? [String] {
                for route in routes {
                    if let _ = convertToIPv4Route(string: route) {
                        if !includedRoutes.contains(route) {
                            shouldUpdate = true
                            includedRoutes.append(route)
                        }
                    } else {
                        fail("An invalid route was provided - \(route)")
                        return
                    }
                }

                if shouldUpdate {
                    reapplyIPv4Settings() { error in
                        if let error = error {
                            fail("Failed to add included routes to tunnel settings - \(error)")
                            return
                        }
                        ok()
                    }
                } else {
                    ok()
                }
            }
        case "removeIncludedRoutes":
            var shouldUpdate = false
            if let routes = obj["routes"] as? [String] {
                for route in routes {
                    if let idx = includedRoutes.firstIndex(of: route) {
                        shouldUpdate = true
                        includedRoutes.remove(at: idx)
                    }
                }
                if shouldUpdate {
                    reapplyIPv4Settings() { error in
                        if let error = error {
                            fail("Failed to remove included routes from tunnel settings - \(error)")
                            return
                        }
                        ok()
                    }
                } else {
                    ok()
                }
            }
        case "addExcludedRoutes":
            var shouldUpdate: Bool = false
            if let routes = obj["routes"] as? [String] {
                for route in routes {
                    if let _ = convertToIPv4Route(string: route) {
                        if !excludedRoutes.contains(route) {
                            shouldUpdate = true
                            excludedRoutes.append(route)
                            if let idx = includedRoutes.firstIndex(of: route) {
                                includedRoutes.remove(at: idx)
                            }
                        }
                    } else {
                        fail("An invalid route was provided - \(route)")
                        return
                    }
                }
                if shouldUpdate {
                    reapplyIPv4Settings() { error in
                        if let error = error {
                            fail("Failed to add excluded routes to tunnel settings - \(error)")
                            return
                        }
                        ok()
                    }
                } else {
                    ok()
                }
            }
        case "removeExcludedRoutes":
            var shouldUpdate = false
            if let routes = obj["routes"] as? [String] {
                for route in routes {
                    if let idx = excludedRoutes.firstIndex(of: route) {
                        shouldUpdate = true
                        excludedRoutes.remove(at: idx)
                    }
                }
                if shouldUpdate {
                    reapplyIPv4Settings() { error in
                        if let error = error {
                            fail("Failed to remove excluded routes from tunnel settings - \(error)")
                            return
                        }
                        ok()
                    }
                } else {
                    ok()
                }
            }
        default:
            fail("unknown cmd \(cmd)")
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
        ipv4Settings.includedRoutes = getIncludedIPv4Routes()
        ipv4Settings.excludedRoutes = getExcludedIPv4Routes()
        tunnelSettings.ipv4Settings = ipv4Settings

        if isDNSActive {
            let dnsSettings = NEDNSSettings(servers: [myIPv4Address])
            dnsSettings.matchDomains = [""]
            tunnelSettings.dnsSettings = dnsSettings
        } else {
            let dnsSettings = NEDNSSettings(servers: [])
            dnsSettings.matchDomains = []
            tunnelSettings.dnsSettings = dnsSettings
        }

        setTunnelNetworkSettings(tunnelSettings) { error in
            if let error = error {
                os_log("Failed to apply tunnel settings: %{public}@", error.localizedDescription)
                completionHandler(error)
            }
            completionHandler(nil)
        }
    }

    func deriveNEProviderStopReason(code: Int) -> String {
        switch code {
        case 0:  return "noReason"
        case 1:  return "stoppedByUser"
        case 2:  return "tunnelFailed"
        case 3:  return "noConnectivity"
        case 4:  return "connectivityChanged."
        case 5:  return "providerDisabled"
        case 6:  return "authenticationCancelled."
        case 7:  return "invalidVPN"
        case 8:  return "timedOut"
        case 9:  return "vpnDisabled"
        case 10: return "vpnRemoved"
        case 11: return "superseded"
        case 12: return "loggedOut"
        case 13: return "currentUserchanged"
        case 14: return "connectionFailed"
        default: return "unknown"
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
        var result: [NEIPv4Route] = [NEIPv4Route(destinationAddress: myIPv4Address,
                                                 subnetMask: "255.255.255.255")]
        for route in includedRoutes {
            if let ipv4Route = convertToIPv4Route(string: route) {
                result.append(ipv4Route)
            }
        }
        return result
    }

    public func getExcludedIPv4Routes() -> [NEIPv4Route] {
        var result: [NEIPv4Route] = [NEIPv4Route.default()]
        for route in excludedRoutes {
            if let ipv4Route = convertToIPv4Route(string: route) {
                if !result.contains(ipv4Route) {
                    result.append(ipv4Route)
                }
            }
        }
        return result
    }

    public func convertToIPv4Route(string: String) -> NEIPv4Route? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }

        let ip = String(parts[0])
        guard isValidIPv4(ip) else { return nil }

        if parts.count == 2 {
            guard let prefix = Int(parts[1]), (0...32).contains(prefix),
                  let mask = subnetMask(fromPrefix: prefix) else { return nil }
            return NEIPv4Route(destinationAddress: ip, subnetMask: mask)
        } else {
            return NEIPv4Route(destinationAddress: ip, subnetMask: "255.255.255.255")
        }
    }
    
    private func validateIPv4HostAddress(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: break
        case 2:
            guard parts[1] == "32" else { return nil }
        default:
            return nil
        }

        let ipStr = String(parts[0])

        var addr = in_addr()
        guard ipStr.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }

        let hostOrder = UInt32(bigEndian: addr.s_addr)
        guard hostOrder != 0x00000000 && hostOrder != 0xFFFFFFFF else { return nil }

        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return buf.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress,
                  inet_ntop(AF_INET, &addr, base, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: base)
        }
    }

    private func isValidIPv4(_ s: String) -> Bool {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard !octet.isEmpty, octet.allSatisfy({ $0.isNumber }) else { return false }
            guard let val = Int(octet), (0...255).contains(val) else { return false }
        }
        return true
    }

    private func subnetMask(fromPrefix p: Int) -> String? {
        guard (0...32).contains(p) else { return nil }
        let mask: UInt32 = p == 0 ? 0 : ~UInt32((1 << (32 - p)) - 1)
        let b1 = (mask >> 24) & 0xFF
        let b2 = (mask >> 16) & 0xFF
        let b3 = (mask >> 8)  & 0xFF
        let b4 = mask & 0xFF
        return "\(b1).\(b2).\(b3).\(b4)"
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
