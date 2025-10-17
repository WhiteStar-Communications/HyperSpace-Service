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
            
            // if we already have an active connection, reject this one immediately
            if let _ = self.currentConnection {
                self.reject(conn,
                            reason: "Another client is already connected")
                return
            }
            
            // accept this connection
            self.currentConnection = conn
            self.readBuffer.removeAll(keepingCapacity: true)
            
            conn.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .failed, .cancelled:
                    // shutdown app when TCP connection goes away
                    self.currentConnection = nil
                    self.readBuffer.removeAll(keepingCapacity: false)
                    self.delimiterTimer?.cancel()
                    self.delimiterTimer = nil
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(nil)
                    }
                default:
                    break
                }
            }
            
            conn.start(queue: self.queue)
            self.readBuffer.reserveCapacity(8 * 1024)
            self.receiveLoop(conn)
            
            vpn.tunnelEventClient.send([
                "event": vpn.vpnApprovalState.rawValue
            ])
            
            self.vpn.tunnelEventClient.send([
                "event": vpn.extensionInstaller.extensionState.rawValue
            ])
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
                    // remove line + delimiter
                    self.readBuffer.removeSubrange(...nl)

                    var lineData = Data(line)
                    while let last = lineData.last, last == 0x0D || last == 0x00 {
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

            if isComplete {
                c.cancel()
                return
            }

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
            if vpn.getStatus() != .connected {
                if cmd == "start" ||
                   cmd == "showVersion" ||
                   cmd == "loadConfig" ||
                   cmd == "loadExtension" ||
                   cmd == "openExtensionSettings" ||
                   cmd == "uninstall" ||
                   cmd == "shutdown" {
                    // continue
                } else {
                    return fail("The tunnel is not started. You can only issue start, shutdown, or uninstall commands until started.")
                }
            }
            
            switch cmd {
            case "openExtensionSettings":
                vpn.openLoginItemsAndExtensions()
                return ok()
            case "loadExtension":
                vpn.extensionInstaller.ensureInstalled()
                return ok()
            case "loadConfig":
                try await vpn.loadOrCreate(shouldSend: true)
                return ok()
            case "start":
                if vpn.getStatus() == .connected {
                    vpn.tunnelEventClient.send([
                        "event": "tunnelStarted"
                    ])
                    return ok()
                } else {
                    try await vpn.loadOrCreate(shouldSend: false)
                    
                    if let myIPv4Address = (req["myIPv4Address"] as? String) {
                        try await vpn.start(myIPv4Address: myIPv4Address)
                        return ok()
                    }
                    return fail("No value provided for myIPv4Address")
                }
            case "getName":
                let rep = try await vpn.send(["cmd":"getName"])
                return rep
            case "turnOnDNS":
                let rep = try await vpn.send(["cmd":"turnOnDNS"])
                return rep
            case "turnOffDNS":
                let rep = try await vpn.send(["cmd":"turnOffDNS"])
                return rep
            case "stop":
                vpn.stop()
                return ok()
            case "status":
                return ok(resultKey: "status",
                          resultValue: statusCodeToString(vpn.getStatus()))
            case "uninstall":
                let uninstaller = ServiceUninstaller(extensionBundleIdentifier: "com.whiteStar.HyperSpaceService.HyperSpaceTunnel")
                
                Task {
                    await uninstaller.uninstallAll()
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(nil)
                    }
                }
                return ok()
            case "showVersion":
                return ok(resultKey: "version",
                          resultValue: AppVersion.appSemanticVersion)
            case "shutdown":
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
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
            return "unknown"
        }
    }
}

