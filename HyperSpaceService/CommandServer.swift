//
//  CommandServer.swift
//  Created by Logan Miller on 8/14/25.
//
//  Copyright (c) 2025, WhiteStar Communications, Inc.
//  All rights reserved.
//  Licensed under the BSD 2-Clause License.
//  See LICENSE file in the project root for details.
//

import Foundation
import Network
import NetworkExtension
import AppKit

final class CommandServer {
    private var listener: NWListener!
    private let vpn: HyperSpaceController
    private let queue = DispatchQueue(label: "commandServer.queue")

    private var currentConnection: NWConnection?
    private var readBuffer = Data()
    private let maxLineBytes = 1 << 20
    private let delimiterTimeout: TimeInterval = 10
    private var delimiterTimer: DispatchSourceTimer?

    init(vpn: HyperSpaceController, port: UInt16 = 5500) throws {
        self.vpn = vpn
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "CommandServer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        
        listener = try NWListener(using: params)
        
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            
            // If we already have an active connection, reject this one immediately.
            if let _ = self.currentConnection {
                self.reject(conn,
                            reason: "Another client is already connected)")
                return
            }
            
            // Accept this connection
            self.currentConnection = conn
            self.readBuffer.removeAll(keepingCapacity: true)
            
            conn.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .failed, .cancelled:
                    // Slot becomes free again
                    self.currentConnection = nil
                    self.readBuffer.removeAll(keepingCapacity: false)
                    self.delimiterTimer?.cancel()
                    self.delimiterTimer = nil
                default:
                    break
                }
            }
            
            conn.start(queue: self.queue)
            self.readBuffer.reserveCapacity(8 * 1024)
            self.receiveLoop(conn)
        }
    }
    
    private func reject(_ c: NWConnection,
                        reason: String? = nil) {
        if let reason {
            c.start(queue: queue)
            let line: [String: Any] = ["ok": false, "error": reason]
            sendLine(line, over: c)
        }
        c.cancel()
    }

    func start() {
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
        currentConnection?.cancel()
        delimiterTimer?.cancel()
        delimiterTimer = nil
        currentConnection = nil
        readBuffer.removeAll(keepingCapacity: false)
    }

    func sendEventToExternalApp(_ dict: [String: Any]) {
        queue.async { [weak self] in
            guard let self,
                  let c = self.currentConnection,
                  let body = try? JSONSerialization.data(withJSONObject: dict)
            else { return }
            var out = Data()
            out.append(body)
            out.append(0x0A)
            c.send(content: out, completion: .contentProcessed { _ in })
        }
    }

    private func receiveLoop(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { c.cancel(); return }
            if c !== self.currentConnection { c.cancel(); return }
            if let _ = error { c.cancel(); return }

            if let data, !data.isEmpty {
                self.readBuffer.append(data)

                if self.readBuffer.count > self.maxLineBytes {
                    c.cancel(); return
                }

                while let nl = self.readBuffer.firstIndex(of: 0x0A) {
                    let line = self.readBuffer[..<nl]
                    // Remove line + delimiter
                    self.readBuffer.removeSubrange(...nl)

                    var lineData = Data(line)
                    while let last = lineData.last, last == 0x0D || last == 0x00{
                        lineData.removeLast()
                    }

                    if !lineData.isEmpty {
                        if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                            Task { @MainActor in
                                let reply = await self.dispatch(obj)
                                self.sendLine(reply, over: c)
                            }
                        } else {
                            self.sendLine(["ok": false, "error": "invalid json"], over: c)
                        }
                    }

                    self.setDelimiterTimer(on: self.queue, conn: c)
                }

                if self.readBuffer.isEmpty {
                    self.delimiterTimer?.cancel()
                    self.delimiterTimer = nil
                } else if self.readBuffer.last != 0x0A {
                    self.setDelimiterTimer(on: self.queue, conn: c)
                }
            }

            if isComplete { c.cancel(); return }

            self.receiveLoop(c)
        }
    }
    
    private func setDelimiterTimer(on queue: DispatchQueue,
                                   conn: NWConnection) {
        delimiterTimer?.cancel()
        delimiterTimer = nil
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delimiterTimeout)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.readBuffer.isEmpty && self.readBuffer.last != 0x0A {
                conn.cancel()
            }
            self.delimiterTimer?.cancel()
            self.delimiterTimer = nil
        }
        delimiterTimer = t
        t.resume()
    }

    @MainActor
    private func ok() -> [String: Any] {
        ["ok": true]
    }
    
    @MainActor
    private func ok(resultKey: String, resultValue: Any) -> [String: Any] {
        ["ok": true, resultKey: resultValue]
    }

    @MainActor
    private func fail(_ message: String, code: Int? = nil) -> [String: Any] {
        if let code = code {
            return ["ok": false, "error": message, "code": code]
        } else {
            return ["ok": false, "error": message]
        }
    }

    @MainActor
    private func dispatch(_ req: [String: Any]) async -> [String: Any] {
        guard let cmd = req["cmd"] as? String else { return fail("missing cmd") }
        do {
            switch cmd {
            case "start":
                try await vpn.loadOrCreate()
                
                if let myIPv4Address = (req["myIPv4Address"] as? String) {
                    let included = (req["includedRoutes"] as? [String]) ?? []
                    let excluded = (req["excludedRoutes"] as? [String]) ?? []
                    let dnsMatchDomains = (req["dnsMatchDomains"] as? [String]) ?? []
                    let dnsSearchDomains = (req["dnsSearchDomains"] as? [String]) ?? []
                    let dnsMatchMap = (req["dnsMatchMap"] as? [String: [String]]) ?? [:]
                    try await vpn.start(myIPv4Address: myIPv4Address,
                                        included: included,
                                        excluded: excluded,
                                        dnsMatchDomains: dnsMatchDomains,
                                        dnsSearchDomains: dnsSearchDomains,
                                        dnsMatchMap: dnsMatchMap)
                    return ok()
                }
                return fail("No value provided for myIPv4Address")
            case "getName":
                let rep = try await vpn.send(["cmd":"getName"])
                return rep
            case "stop":
                vpn.stop()
                return ok()
            case "status":
                return ok(resultKey: "status",
                          resultValue: statusCodeToString(vpn.status))
            case "uninstall":
                let uninstaller = ServiceUninstaller(extensionBundleIdentifier: "com.whiteStar.HyperSpaceService.HyperSpaceTunnel")
                
                Task {
                    await uninstaller.uninstallAll()
                    NSApp.terminate(nil)
                }
                return ok()
            case "showVersion":
                return ok(resultKey: "version",
                          resultValue: AppVersion.appSemanticVersion)
            case "shutdown":
                vpn.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    exit(0)
                }
                return ok()
            case "addIncludedRoutes":
                var dict: [String:Any] = [:]
                dict["cmd"] = "addIncludedRoutes"
                if let routes = (req["routes"] as? [String]) {
                    dict["routes"] = routes
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No included routes were provided")
                }
            case "removeIncludedRoutes":
                var dict: [String:Any] = [:]
                dict["cmd"] = "removeIncludedRoutes"
                if let routes = (req["routes"] as? [String]) {
                    dict["routes"] = routes
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No included routes were provided")
                }
            case "addExcludedRoutes":
                var dict: [String:Any] = [:]
                dict["cmd"] = "addExcludedRoutes"
                if let routes = (req["routes"] as? [String]) {
                    dict["routes"] = routes
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No excluded routes were provided")
                }
            case "removeExcludedRoutes":
                var dict: [String:Any] = [:]
                dict["cmd"] = "removeExcludedRoutes"
                if let routes = (req["routes"] as? [String]) {
                    dict["routes"] = routes
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No excluded routes were provided")
                }
            case "addDNSMatchEntries":
                var dict: [String:Any] = [:]
                dict["cmd"] = "addDNSMatchEntries"
                if let map = (req["map"] as? [String: [String]]) {
                    dict["map"] = map
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No DNS match entries were provided")
                }
            case "removeDNSMatchEntries":
                var dict: [String:Any] = [:]
                dict["cmd"] = "removeDNSMatchEntries"
                if let map = (req["map"] as? [String: [String]]) {
                    dict["map"] = map
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No DNS match entries were provided")
                }
            case "addDNSMatchDomains":
                var dict: [String:Any] = [:]
                dict["cmd"] = "addDNSMatchDomains"
                if let domains = (req["domains"] as? [String]) {
                    dict["domains"] = domains
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No dns match domains were provided")
                }
            case "removeDNSMatchDomains":
                var dict: [String:Any] = [:]
                dict["cmd"] = "removeDNSMatchDomains"
                if let domains = (req["domains"] as? [String]) {
                    dict["domains"] = domains
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No dns match domains were provided")
                }
            case "addDNSSearchDomains":
                var dict: [String:Any] = [:]
                dict["cmd"] = "addDNSSearchDomains"
                if let domains = (req["domains"] as? [String]) {
                    dict["domains"] = domains
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No dns search domains were provided")
                }
            case "removeDNSSearchDomains":
                var dict: [String:Any] = [:]
                dict["cmd"] = "removeDNSSearchDomains"
                if let domains = (req["domains"] as? [String]) {
                    dict["domains"] = domains
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No dns Search domains were provided")
                }
            case "addDNSServers":
                var dict: [String:Any] = [:]
                dict["cmd"] = "addDNSServers"
                if let servers = (req["servers"] as? [String]) {
                    dict["servers"] = servers
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No DNS servers were provided")
                }
            case "removeDNSServers":
                var dict: [String:Any] = [:]
                dict["cmd"] = "removeDNSServers"
                if let servers = (req["servers"] as? [String]) {
                    dict["servers"] = servers
                    let rep = try await vpn.send(dict)
                    return rep
                } else {
                    return fail("No DNS servers were provided")
                }
            default:
                return fail("unknown cmd")
            }
        } catch {
            let ns = error as NSError
            return fail(ns.localizedDescription, code: ns.code)
        }
    }

    private func sendLine(_ dict: [String: Any], over c: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: dict) else {
            c.cancel(); return
        }
        var out = Data(capacity: body.count + 1)
        out.append(body)
        out.append(0x0A)
        c.send(content: out, completion: .contentProcessed { _ in })
    }
    
    public func statusCodeToString(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid:
            return "invalid"
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reasserting:
            return "reasserting"
        case .disconnecting:
            return "disconnecting"
        @unknown default:
            return "unknown status"
        }
    }
}

