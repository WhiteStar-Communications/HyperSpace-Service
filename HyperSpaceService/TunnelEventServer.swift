//
//  TunnelEventServer.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/25/25.
//

import Foundation
import Network

final class TunnelEventServer {
    private let queue = DispatchQueue(label: "tunnelEventServer.queue")
    private var listener: NWListener!
    private let maxFrame = 1 * 1024 * 1024 // 1MB cap

    /// App wires this to do something with the event (e.g., forward to Java).
    var onEvent: (([String: Any]) -> Void)?

    init(port: UInt16 = 5503) throws {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "TunnelEventServer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: p)

        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receiveOneFrame(conn)
        }
    }

    func start() { listener.start(queue: queue) }
    func cancel() { listener.cancel() }

    private func receiveOneFrame(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] hdr, _, _, e in
            guard let self else { c.cancel(); return }
            guard e == nil, let hdr, hdr.count == 4 else { c.cancel(); return }
            let n = hdr.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            guard n > 0, n <= self.maxFrame else { c.cancel(); return }
            c.receive(minimumIncompleteLength: Int(n), maximumLength: Int(n)) { [weak self] body, _, _, e2 in
                guard let self else { return }
                defer { c.cancel() } // one-shot
                guard e2 == nil, let body, body.count == Int(n) else { return }
                if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                    DispatchQueue.main.async { self.onEvent?(obj) }
                }
            }
        }
    }
}

