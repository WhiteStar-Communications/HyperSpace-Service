//
//  TunnelEventServer.swift
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

final class TunnelEventServer {
    private let queue = DispatchQueue(label: "tunnelEventServer.queue")
    private var listener: NWListener!
    private let maxFrame = 1 * 1024 * 1024

    var onEvent: (([String: Any]) -> Void)?

    init(port: UInt16 = 5600) throws {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "TunnelEventServer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }

        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: p)

        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.handleConnection(conn)
        }
    }

    func start() { listener.start(queue: queue) }
    func cancel() { listener.cancel() }

    private func handleConnection(_ c: NWConnection) {
        var buffer = Data()

        func receiveNext() {
            c.receive(minimumIncompleteLength: 1, maximumLength: maxFrame) { [weak self] data, _, isComplete, error in
                guard let self else { c.cancel(); return }

                if let data, !data.isEmpty {
                    buffer.append(data)

                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[..<nl]
                        if !line.isEmpty,
                           let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                            DispatchQueue.main.async { self.onEvent?(obj) }
                        }
                        buffer.removeSubrange(..<buffer.index(after: nl))
                        if buffer.count > self.maxFrame { buffer.removeAll(keepingCapacity: false) }
                    }
                }

                if let error = error {
                    c.cancel()
                    return
                }

                if isComplete {
                    c.cancel()
                    return
                }

                receiveNext()
            }
        }

        receiveNext()
    }
}

