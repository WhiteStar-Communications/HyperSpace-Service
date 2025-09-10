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

final class CommandServer {
    private var listener: NWListener!
    private let vpn: HyperSpaceController
    private let queue = DispatchQueue(label: "commandServer.queue")
    private var currentConnection: NWConnection?

    init(vpn: HyperSpaceController,
         port: UInt16 = 5500) throws {
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
            self.currentConnection?.cancel()
            self.currentConnection = conn
            conn.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                if case .failed = st { self.currentConnection = nil }
                if case .cancelled = st { self.currentConnection = nil }
            }
            conn.start(queue: self.queue)
            self.receiveLoop(conn)
        }
    }

    func start() {
        listener.start(queue: queue)
    }
    
    func cancel() {
        listener.cancel()
        currentConnection?.cancel()
        currentConnection = nil
    }

    func sendEventToExternalApp(_ dict: [String: Any]) {
        queue.async { [weak self] in
            guard let self,
                  let c = self.currentConnection,
                  let body = try? JSONSerialization.data(withJSONObject: dict) else { return }
            
            var len = UInt32(body.count).bigEndian
            let hdr = Data(bytes: &len, count: 4)
            c.send(content: hdr + body, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Request/Reply loop
    private func receiveLoop(_ c: NWConnection) {
        recvFrame(on: c) { [weak self] data in
            guard let self else { c.cancel(); return }
            guard let data else { c.cancel(); return }

            Task { @MainActor in
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let reply = await self.dispatch(obj)
                self.sendFrame(reply, over: c) {
                    self.receiveLoop(c)
                }
            }
        }
    }

    // MARK: - Dispatch helpers
    @MainActor
    private func ok(_ payload: [String: Any] = [:]) -> [String: Any] {
        payload.isEmpty ? ["ok": true] : ["ok": true, "data": payload]
    }

    @MainActor
    private func fail(_ message: String, code: Int = 400) -> [String: Any] {
        ["ok": false, "error": message, "code": code]
    }

    // MARK: - Command dispatcher
    @MainActor
    private func dispatch(_ req: [String: Any]) async -> [String: Any] {
        guard let cmd = req["cmd"] as? String else { return fail("missing cmd") }
        do {
            switch cmd {
            case "load":
                try await vpn.loadOrCreate()
                return ok()
            case "start":
                let myIPv4Address = (req["myIPv4Address"] as? String) ?? ""
                let included = (req["includedRoutes"] as? [String]) ?? []
                let excluded = (req["excludedRoutes"] as? [String]) ?? []
                let dnsMatches = (req["dnsMatches"] as? [String]) ?? []
                let dnsMap = (req["dnsMap"] as? [String: [String]]) ?? [:]
                try await vpn.start(myIPv4Address: myIPv4Address,
                                    included: included,
                                    excluded: excluded,
                                    dnsMatches: dnsMatches,
                                    dnsMap: dnsMap)
                return ok()
            case "stop":
                vpn.stop()
                return ok()
            case "status":
                return ok(["status": vpn.status.rawValue])
            case "update":
                var dict: [String:Any] = [:]
                dict["command"] = "update"
                
                if let included = (req["includedRoutes"] as? [String]) {
                    dict["includedRoutes"] = included
                }
                if let excluded = (req["excludedRoutes"] as? [String]) {
                    dict["excludedRoutes"] = excluded
                }
                if let dnsMatches = (req["dnsMatches"] as? [String]) {
                    dict["dnsMatches"] = dnsMatches
                }
                if let dnsMap = (req["dnsMap"] as? [String: [String]]) {
                    dict["dnsMap"] = dnsMap
                }
                
                let rep = try await vpn.send(dict)
                return ok(["reply": rep])
            default:
                return fail("unknown cmd `\(cmd)`", code: 404)
            }
        } catch {
            let ns = error as NSError
            return fail(ns.localizedDescription, code: ns.code)
        }
    }

    // MARK: - Framing helpers
    private func recvFrame(on c: NWConnection, _ done: @escaping (Data?) -> Void) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { hdr, _, _, e in
            guard e == nil, let hdr, hdr.count == 4 else { done(nil); return }
            let len = hdr.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
            guard len > 0, len < 16 * 1024 * 1024 else { done(nil); return } // sanity
            c.receive(minimumIncompleteLength: Int(len), maximumLength: Int(len)) { body, _, _, e2 in
                guard e2 == nil, let body, body.count == Int(len) else { done(nil); return }
                done(body)
            }
        }
    }

    private func sendFrame(_ dict: [String: Any], over c: NWConnection, then: @escaping () -> Void) {
        guard let body = try? JSONSerialization.data(withJSONObject: dict) else {
            c.cancel(); return
        }
        var len = UInt32(body.count).bigEndian
        let hdr = Data(bytes: &len, count: 4)
        c.send(content: hdr + body, completion: .contentProcessed { _ in then() })
    }
}
