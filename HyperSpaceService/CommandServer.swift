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
    private let queue = DispatchQueue(label: "cmd.server.accept")

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
            conn.start(queue: self.queue)
            self.receiveLoop(conn)
        }
    }

    func start() { listener.start(queue: queue) }
    func cancel() { listener.cancel() }

    // MARK: - Request/Reply loop (framed JSON)

    private func receiveLoop(_ c: NWConnection) {
        recvFrame(on: c) { [weak self] data in
            guard let self else { c.cancel(); return }
            guard let data else { c.cancel(); return }

            Task { @MainActor in
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let reply = await self.dispatch(obj)
                self.sendFrame(reply, over: c) {
                    // continue serving same connection
                    self.receiveLoop(c)
                }
            }
        }
    }

    // MARK: - Dispatch helpers

    @MainActor
    private func ack(_ payload: [String: Any] = [:]) -> [String: Any] {
        ["ack": true, "data": payload]
    }

    @MainActor
    private func fail(_ message: String, code: Int = 400) -> [String: Any] {
        ["fail": false, "error": message, "code": code]
    }

    private func asString(_ any: Any?, key: String) throws -> String {
        if let s = any as? String, !s.isEmpty { return s }
        throw NSError(domain: "cmd", code: 400,
                      userInfo: [NSLocalizedDescriptionKey: "missing or invalid `\(key)`"])
    }

    private func asStringArray(_ any: Any?, key: String) throws -> [String] {
        if let arr = any as? [String], !arr.isEmpty { return arr }
        throw NSError(domain: "cmd", code: 400,
                      userInfo: [NSLocalizedDescriptionKey: "missing or invalid `\(key)`[]"])
    }

    // MARK: - Command dispatcher

    @MainActor
    private func dispatch(_ req: [String: Any]) async -> [String: Any] {
        guard let op = req["op"] as? String else { return fail("missing op") }

        do {
            switch op {
            case "load":
                try await vpn.loadOrCreate()
                return ack()

            case "start":
                // Optional options
                let myIPv4Address = (req["myIPv4Address"] as? String) ?? "10.0.0.1"
                let included = (req["included"] as? [String]) ?? []
                let excluded = (req["excluded"] as? [String]) ?? []
                try await vpn.start(myIPv4Address: myIPv4Address,
                                    included: included,
                                    excluded: excluded)
                return ack()

            case "stop":
                vpn.stop()
                return ack()

            case "status":
                return ack(["status": vpn.status.rawValue])

            case "addRoute":
                let route = try asString(req["route"], key: "route")
                let rep = try await vpn.send(["cmd": "addRoute", "route": route])
                return ack(["reply": rep])

            case "removeRoute":
                let route = try asString(req["route"], key: "route")
                let rep = try await vpn.send(["cmd": "removeRoute", "route": route])
                return ack(["reply": rep])

            case "addRoutes":
                let routes = try asStringArray(req["routes"], key: "routes")
                let rep = try await vpn.send(["cmd": "addRoutes", "routes": routes])
                return ack(["reply": rep])

            case "removeRoutes":
                let routes = try asStringArray(req["routes"], key: "routes")
                let rep = try await vpn.send(["cmd": "removeRoutes", "routes": routes])
                return ack(["reply": rep])

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
