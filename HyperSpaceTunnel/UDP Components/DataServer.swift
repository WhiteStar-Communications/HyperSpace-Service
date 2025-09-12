//
//  DataServer.swift
//
//  Created by Logan Miller on 9/9/25.
//
//  Copyright (c) 2025, WhiteStar Communications, Inc.
//  All rights reserved.
//  Licensed under the BSD 2-Clause License.
//  See LICENSE file in the project root for details.
//

import Foundation

final class DataServer {
    private let endpoint: DataEndpoint
    private unowned let bridge: TUNInterfaceBridge
    private let mtuCap: Int = 65507

    init?(port: UInt16,
          bridge: TUNInterfaceBridge?) {
        guard let bridge = bridge,
              let endpoint = DataEndpoint(port: port) else { return nil }
        
        self.bridge = bridge
        self.endpoint = endpoint
    }

    func start() {
        endpoint.onDatagram = { [weak self] bytes, _, _ in
            guard let self else { return }
            let n = bytes.count
            guard n > 0 && n <= self.mtuCap else { return }

            let first = bytes[0]
            guard (first >> 4) == 4 else { return }

            let ihl = Int(first & 0x0F)
            guard ihl >= 5 else { return }

            let data = Data(bytes: bytes.baseAddress!, count: n)
            self.bridge.writePacket(toTun: data)
        }
        endpoint.start()
    }

    func stop() {
        endpoint.stop()
    }

    func sendPacketsToExternalApp(_ ipv4Packet: [UInt8]) {
        guard let b0 = ipv4Packet.first, (b0 >> 4) == 4 else { return }
        endpoint.reply(ipv4Packet)
    }
}
