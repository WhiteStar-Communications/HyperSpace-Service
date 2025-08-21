//
//  DataPipe.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/21/25.
//

import Foundation
import Network

/// A simple framed-data TCP server for the dataplane.
/// Each frame = 4-byte little-endian length prefix + payload.
final class DataPipe {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let q = DispatchQueue(label: "data.pipe.queue")

    /// Called when the extension sends one or more packets up to the app.
    var onPacketsFromExtension: (([Data]) -> Void)?

    init(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "DataPipe", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.connections.append(conn)
            conn.start(queue: self.q)
            self.readLoop(conn)
        }
    }

    func start() { listener.start(queue: q) }
    func cancel() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    // MARK: - Sending packets down to the extension

    /// Send a single packet down to the extension.
    func sendPacketToExtension(_ pkt: Data) {
        sendPacketsToExtension([pkt])
    }

    /// Send multiple packets efficiently in one write.
    func sendPacketsToExtension(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        for conn in connections {
            var out = Data()
            out.reserveCapacity(packets.reduce(0) { $0 + 4 + $1.count })
            for p in packets {
                var lenLE = UInt32(p.count).littleEndian
                out.append(Data(bytes: &lenLE, count: 4))
                out.append(p)
            }
            conn.send(content: out, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Reading from extension

    private func readLoop(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.processFrames(data, from: c)
            }

            if isComplete || err != nil {
                c.cancel()
                self.connections.removeAll { $0 === c }
                return
            }

            self.readLoop(c)
        }
    }

    // Buffer per connection for partial reads
    private var rxBuffers: [ObjectIdentifier: Data] = [:]

    private func processFrames(_ chunk: Data, from c: NWConnection) {
        let key = ObjectIdentifier(c)
        var buf = rxBuffers[key] ?? Data()
        buf.append(chunk)

        var batch: [Data] = []
        while buf.count >= 4 {
            let lenLE = buf.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            let n = Int(lenLE)
            guard n > 0, n <= 8 * 1024 * 1024 else {
                c.cancel()
                rxBuffers.removeValue(forKey: key)
                return
            }
            let need = 4 + n
            guard buf.count >= need else { break }

            let pkt = buf.subdata(in: 4..<need)
            buf.removeSubrange(0..<need)
            batch.append(pkt)
        }

        if !batch.isEmpty {
            onPacketsFromExtension?(batch)
        }
        rxBuffers[key] = buf
    }
}
