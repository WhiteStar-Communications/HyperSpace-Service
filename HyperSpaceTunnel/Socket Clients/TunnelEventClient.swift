//
//  TunnelEventClient.swift
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/26/25.
//

import Foundation
import Network

final class TunnelEventClient {
    private let host: NWEndpoint.Host = .ipv4(.loopback)
    private let port: NWEndpoint.Port
    private let q = DispatchQueue(label: "tunnelEventClient.queue")
    private var conn: NWConnection?
    private var isReady = false
    private var pending: [Data] = []

    init(port: UInt16 = 5503) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() {
        q.async { self.open() }
    }

    func stop() {
        q.async {
            self.conn?.cancel()
            self.conn = nil
            self.isReady = false
            self.pending.removeAll(keepingCapacity: false)
        }
    }

    private func open() {
        guard conn == nil else { return }
        let c = NWConnection(host: host, port: port, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.isReady = true
                self.flushPending()
            case .failed, .cancelled:
                self.isReady = false
                // No auto-reconnect here; add if desired.
            default:
                break
            }
        }
        c.start(queue: q)
    }

    private func frame(_ obj: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        var len = UInt32(body.count).littleEndian
        var out = Data(bytes: &len, count: 4)
        out.append(body)
        return out
    }

    private func flushPending() {
        guard isReady, let c = conn, !pending.isEmpty else { return }
        pending.forEach { f in c.send(content: f, completion: .contentProcessed { _ in }) }
        pending.removeAll(keepingCapacity: false)
    }

    /// Regular async send; queues if not ready yet.
    func send(_ obj: [String: Any]) {
        guard let framed = frame(obj) else { return }
        q.async {
            if self.isReady, let c = self.conn {
                c.send(content: framed, completion: .contentProcessed { _ in })
            } else {
                if self.conn == nil { self.open() }
                self.pending.append(framed)
            }
        }
    }

    /// Best-effort synchronous send for stopTunnel: waits briefly for send.
    func sendSync(_ obj: [String: Any], timeout: TimeInterval = 0.5) {
        guard let framed = frame(obj) else { return }
        let sema = DispatchSemaphore(value: 0)
        q.async {
            if self.isReady, let c = self.conn {
                c.send(content: framed, completion: .contentProcessed { _ in sema.signal() })
            } else {
                if self.conn == nil { self.open() }
                // Try to wait for ready and then flush
                self.pending.append(framed)
                // If we’re not ready, we still return after timeout.
            }
        }
        _ = sema.wait(timeout: .now() + timeout)
    }
}

