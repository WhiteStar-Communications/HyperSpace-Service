//
//  DataServer.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/14/25.
//

import Foundation
import Network

// MARK: - Delegate

protocol DataServerDelegate: AnyObject {
    /// A single framed packet arrived from the extension/tunnel.
    func dataServer(_ server: DataServer, didReceivePacket data: Data)

    /// Optional: multiple packets parsed from a single read.
    func dataServer(_ server: DataServer, didReceivePackets packets: [Data])

    /// The tunnel-side client connected/disconnected.
    func dataServerDidConnect(_ server: DataServer)
    func dataServerDidDisconnect(_ server: DataServer, error: Error?)
}

extension DataServerDelegate {
    func dataServer(_ server: DataServer, didReceivePackets packets: [Data]) {}
    func dataServerDidConnect(_ server: DataServer) {}
    func dataServerDidDisconnect(_ server: DataServer, error: Error?) {}
}

import Foundation
import Network

/// JSON packet server (loopback) mirroring CommandServer structure.
/// Accepts framed JSON with two ops:
///  - {"op":"inject","pkt":"<base64>"}
///  - {"op":"injectBatch","pkts":["<base64>", ...]}
///
/// Frame: [u32 little-endian length][UTF-8 JSON]
final class DataServer {
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

            // Mirror CommandServer style: parse, dispatch, reply, loop
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let reply = self.dispatch(obj)
            self.sendFrame(reply, over: c) {
                self.receiveLoop(c)
            }
        }
    }

    // MARK: - Dispatch helpers (same shape as CommandServer)

    private func ok(_ payload: [String: Any] = [:]) -> [String: Any] {
        ["ok": true, "data": payload]
    }

    private func fail(_ message: String, code: Int = 400) -> [String: Any] {
        ["ok": false, "error": message, "code": code]
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

    // MARK: - Command dispatcher (packets only)

    /// Note: this class is *packets-only* JSON, separate from CommandServer.
    private func dispatch(_ req: [String: Any]) -> [String: Any] {
        guard let op = req["op"] as? String else { return fail("missing op") }

        do {
            switch op {
            case "inject": {
                guard let b64 = try? asString(req["pkt"], key: "pkt"),
                      let pkt = Data(base64Encoded: b64) else { return fail("invalid base64 in `pkt`") }
                // decoded → into our “incoming” path
                sendIncomingPacket(pkt)
                return ok()
            }()

            case "injectBatch": {
                guard let b64s = try? asStringArray(req["pkts"], key: "pkts") else { return fail("no decodable packets") }
                let decoded = b64s.compactMap { Data(base64Encoded: $0) }
                guard !decoded.isEmpty else { return fail("no decodable packets") }
                sendIncomingPackets(decoded)
                return ok(["count": decoded.count])
            }()

            default:
                return fail("unknown op `\(op)`", code: 404)
            }
        } catch {
            let ns = error as NSError
            return fail(ns.localizedDescription, code: ns.code)
        }
        
        return [:]
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

    // MARK: - Framing helpers (same as CommandServer)

    private func recvFrame(on c: NWConnection, _ done: @escaping (Data?) -> Void) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { hdr, _, _, e in
            guard e == nil, let hdr, hdr.count == 4 else { done(nil); return }
            let len = hdr.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            guard len > 0, len <= self.maxFrame else { done(nil); return } // sanity
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
