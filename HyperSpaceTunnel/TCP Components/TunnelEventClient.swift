//
//  TunnelEventClient.swift
//
//  Created by Logan Miller on 8/14/25.
//
//  Copyright (c) 2025, WhiteStar Communications, Inc.
//  All rights reserved.
//  Licensed under the BSD 2-Clause License.
//  See LICENSE file in the project root for details.
//

import Foundation
import Network

final class TunnelEventClient {
    private let host: NWEndpoint.Host = .ipv4(.loopback)
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "tunnelEventClient.queue")
    private var connection: NWConnection?
    private var isReady = false
    private var pending: [Data] = []

    init(port: UInt16 = 5600) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() {
        queue.async { self.open() }
    }

    func stop() {
        queue.async {
            self.connection?.cancel()
            self.connection = nil
            self.isReady = false
            self.pending.removeAll(keepingCapacity: false)
        }
    }

    private func open() {
        guard connection == nil else { return }
        let c = NWConnection(host: host, port: port, using: .tcp)
        connection = c
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
        c.start(queue: queue)
    }

    private func frame(_ obj: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        var len = UInt32(body.count).bigEndian
        var out = Data(bytes: &len, count: 4)
        out.append(body)
        return out
    }

    private func flushPending() {
        guard isReady, let c = connection, !pending.isEmpty else { return }
        pending.forEach { f in c.send(content: f, completion: .contentProcessed { _ in }) }
        pending.removeAll(keepingCapacity: false)
    }

    /// Regular async send; queues if not ready yet.
    func send(_ obj: [String: Any]) {
        guard let framed = frame(obj) else { return }
        queue.async {
            if self.isReady, let c = self.connection {
                c.send(content: framed, completion: .contentProcessed { _ in })
            } else {
                if self.connection == nil { self.open() }
                self.pending.append(framed)
            }
        }
    }

    /// Best-effort synchronous send for stopTunnel: waits briefly for send.
    func sendSync(_ obj: [String: Any], timeout: TimeInterval = 0.5) {
        guard let framed = frame(obj) else { return }
        let sema = DispatchSemaphore(value: 0)
        queue.async {
            if self.isReady, let c = self.connection {
                c.send(content: framed, completion: .contentProcessed { _ in sema.signal() })
            } else {
                if self.connection == nil { self.open() }
                // Try to wait for ready and then flush
                self.pending.append(framed)
                // If we’re not ready, we still return after timeout.
            }
        }
        _ = sema.wait(timeout: .now() + timeout)
    }
}

