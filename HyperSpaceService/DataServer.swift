//
//  DataServer.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/14/25.
//

import Foundation
import Network

final class DataServer {
    // Single Java peer (simplest model). If you need multi-peer later,
    // change this to a Set<NWConnection>.
    private var conn: NWConnection?
    private var isReady = false

    private let queue = DispatchQueue(label: "data.json.server.accept")
    private var listener: NWListener!
    private let maxFrame = 8 * 1024 * 1024 // 8MB sanity cap

    /// Wire this from your app to forward decoded packets into the extension’s binary pipe.
    /// Example:
    ///   dataServer.onInjectPackets = { packets in binaryPipe.sendPacketsToExtension(packets) }
    var onInjectPackets: (([Data]) -> Void)?

    init(port: UInt16 = 5501) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "DataServer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        listener = try NWListener(using: params)

        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }

            // Replace any existing connection
            self.conn?.cancel()
            self.conn = c
            self.isReady = false

            c.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready:
                    self.isReady = true
                    // Start read loop once ready
                    self.receiveLoop(c)
                case .failed, .cancelled:
                    self.isReady = false
                    if self.conn === c { self.conn = nil }
                default:
                    break
                }
            }

            c.start(queue: self.queue)
        }
    }

    func start() { listener.start(queue: queue) }

    func cancel() {
        listener.cancel()
        conn?.cancel()
        conn = nil
        isReady = false
    }

    // MARK: - Incoming (Java -> App -> Extension)
    private func receiveLoop(_ c: NWConnection) {
        recvFrame(on: c) { [weak self] data in
            guard let self else { c.cancel(); return }
            guard let data else { c.cancel(); return }

            // Mirror CommandServer style: parse, dispatch, reply, loop
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let reply = self.dispatch(obj)
            self.sendFrame(reply, over: c) {
                self.receiveLoop(c)
            }
        }
    }

    private func ack(_ payload: [String: Any] = [:]) -> [String: Any] {
        ["ack": true, "data": payload]
    }

    private func fail(_ message: String, code: Int = 400) -> [String: Any] {
        ["fail": false, "error": message, "code": code]
    }

    private func asString(_ any: Any?, key: String) throws -> String {
        if let s = any as? String, !s.isEmpty { return s }
        throw NSError(domain: "data", code: 400,
                      userInfo: [NSLocalizedDescriptionKey: "missing or invalid `\(key)`"])
    }

    private func asStringArray(_ any: Any?, key: String) throws -> [String] {
        if let arr = any as? [String], !arr.isEmpty { return arr }
        throw NSError(domain: "data", code: 400,
                      userInfo: [NSLocalizedDescriptionKey: "missing or invalid `\(key)`[]"])
    }

    /// Packets-only JSON dispatcher.
    private func dispatch(_ req: [String: Any]) -> [String: Any] {
        guard let op = req["op"] as? String else { return fail("missing op") }

        do {
            switch op {
            // {"op":"inject","packet":["<b641>", "<b642>", "..."]}
            case "inject":
                guard let b64 = try? asString(req["packet"], key: "packet"),
                      let pkt = Data(base64Encoded: b64)
                else { return fail("invalid base64 in `packet`") }
                sendIncomingPacket(pkt)
                return ack()

            // {"op":"injectBatch","packets":["<b641>", "<b642>", "..."]}
            case "injectBatch":
                let b64s = try asStringArray(req["packets"], key: "packets")
                let decoded = b64s.compactMap { Data(base64Encoded: $0) }
                guard !decoded.isEmpty else { return fail("no decodable packets") }
                sendIncomingPackets(decoded)
                return ack(["count": decoded.count])

            default:
                return fail("unknown op `\(op)`", code: 404)
            }
        } catch {
            let ns = error as NSError
            return fail(ns.localizedDescription, code: ns.code)
        }
    }

    /// Single decoded packet destined for the extension/tun.
    func sendIncomingPacket(_ packet: Data) {
        guard !packet.isEmpty else { return }
        onInjectPackets?([packet])
    }

    /// Batch of decoded packets destined for the extension/tun.
    func sendIncomingPackets(_ packets: [Data]) {
        let nonEmpty = packets.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }
        onInjectPackets?(nonEmpty)
    }

    // MARK: - Outgoing (App -> Java) as JSON

    /// Send many packets to Java as one JSON frame: {"op":"packets","packets":["<b64>", ...]}
    func sendOutgoingPackets(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.isReady, let c = self.conn else { return }

            let b64s = packets.compactMap { $0.isEmpty ? nil : $0.base64EncodedString() }
            guard !b64s.isEmpty else { return }

            let obj: [String: Any] = ["op": "packets", "packets": b64s]
            guard let body = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return }

            var lenLE = UInt32(body.count).littleEndian
            var framed = Data(bytes: &lenLE, count: 4)
            framed.append(body)

            c.send(content: framed, completion: .contentProcessed { _ in })
        }
    }

    /// Send one packet to Java: {"op":"packet","packet":"<b64>"}
    func sendOutgoingPacket(_ packet: Data) {
        guard !packet.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.isReady, let c = self.conn else { return }
            let obj: [String: Any] = ["op": "packet", "packet": packet.base64EncodedString()]
            guard let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
            var lenLE = UInt32(body.count).littleEndian
            var framed = Data(bytes: &lenLE, count: 4)
            framed.append(body)
            c.send(content: framed, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Framing helpers

    private func recvFrame(on c: NWConnection, _ done: @escaping (Data?) -> Void) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { hdr, _, _, e in
            guard e == nil, let hdr, hdr.count == 4 else { done(nil); return }
            let len = hdr.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            guard len > 0, len <= self.maxFrame else { done(nil); return }
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
