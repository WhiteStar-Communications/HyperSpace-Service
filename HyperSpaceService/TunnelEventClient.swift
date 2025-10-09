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
    private struct Item {
        let data: Data
        let sema: DispatchSemaphore?
    }

    private let host: NWEndpoint.Host = .ipv4(.loopback)
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "tunnelEventClient.queue")

    private var connection: NWConnection?
    private var isReady = false
    private var isSending = false
    private var pending: [Item] = []

    init(port: UInt16 = 5600) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() {
        queue.async { self.openIfNeeded() }
    }

    func stop() {
        queue.async {
            self.connection?.cancel()
            self.connection = nil
            self.isReady = false
            self.isSending = false
            self.pending.removeAll(keepingCapacity: false)
        }
    }

    private func openIfNeeded() {
        guard connection == nil else { return }

        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let c = NWConnection(host: host, port: port, using: params)
        connection = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.isReady = true
                self.pumpIfNeeded()
            case .failed, .cancelled, .waiting:
                self.isReady = false
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func frame(_ obj: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(obj),
              let body = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return nil }
        var out = Data()
        out.append(body)
        out.append(0x0A)
        return out
    }

    private func enqueue(_ item: Item) {
        pending.append(item)
    }

    private func pumpIfNeeded() {
        guard isReady, !isSending, let c = connection, !pending.isEmpty else { return }
        isSending = true

        let item = pending.removeFirst()
        c.send(content: item.data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            item.sema?.signal()
            self.isSending = false
            self.pumpIfNeeded()
        })
    }

    func send(_ obj: [String: Any]) {
        guard let data = frame(obj) else { return }
        queue.async {
            self.openIfNeeded()
            self.enqueue(Item(data: data, sema: nil))
            self.pumpIfNeeded()
        }
    }

    func sendSync(_ obj: [String: Any], timeout: TimeInterval = 0.5) {
        guard let data = frame(obj) else { return }
        let sema = DispatchSemaphore(value: 0)
        queue.async {
            self.openIfNeeded()
            self.enqueue(Item(data: data, sema: sema))
            self.pumpIfNeeded()
        }
        _ = sema.wait(timeout: .now() + timeout)
    }
}
