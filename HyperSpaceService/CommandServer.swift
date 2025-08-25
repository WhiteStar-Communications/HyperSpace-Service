//
//  CommandServer.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/14/25.
//

import Foundation
import Network

final class CommandServer {
    private var listener: NWListener!
    private let vpn: HyperSpaceController
    private let queue = DispatchQueue(label: "commandServer.queue")
    private var javaConnection: NWConnection?

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
            self.javaConnection?.cancel()
            self.javaConnection = conn
            conn.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                if case .failed = st { self.javaConnection = nil }
                if case .cancelled = st { self.javaConnection = nil }
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
        javaConnection?.cancel()
        javaConnection = nil
    }

    // Push an async event to the Java client
    func sendEventToJava(_ dict: [String: Any]) {
        queue.async { [weak self] in
            guard let self, let c = self.javaConnection,
                  let body = try? JSONSerialization.data(withJSONObject: dict) else { return }
            var len = UInt32(body.count).littleEndian
            let hdr = Data(bytes: &len, count: 4)
            c.send(content: hdr + body, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Request/Reply loop (framed JSON)
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
        guard let op = req["op"] as? String else { return fail("missing op") }
        do {
            switch op {
            case "load":
                try await vpn.loadOrCreate()
                return ok()
            case "start":
                let myIPv4Address = (req["myIPv4Address"] as? String) ?? ""
                let included = (req["includedRoutes"] as? [String]) ?? []
                let excluded = (req["excludedRoutes"] as? [String]) ?? []
                let dnsMap = (req["dnsMap"] as? [String: [String]]) ?? [:]
                try await vpn.start(myIPv4Address: myIPv4Address,
                                    included: included,
                                    excluded: excluded,
                                    dnsMap: dnsMap)
                return ok()
            case "stop":
                vpn.stop()
                return ok()
            case "status":
                return ok(["status": vpn.status.rawValue])
            case "update":
                let included = (req["includedRoutes"] as? [String]) ?? []
                let excluded = (req["excludedRoutes"] as? [String]) ?? []
                let dnsMap = (req["dnsMap"] as? [String: [String]]) ?? [:]
                let rep = try await vpn.send(["command": "update",
                                              "includedRoutes": included,
                                              "excludedRoutes": excluded,
                                              "dnsMap": dnsMap])
                return ok(["reply": rep])
            default:
                return fail("unknown op `\(op)`", code: 404)
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
            let len = hdr.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
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
        var len = UInt32(body.count).littleEndian
        let hdr = Data(bytes: &len, count: 4)
        c.send(content: hdr + body, completion: .contentProcessed { _ in then() })
    }
}
