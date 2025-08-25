//
//  DataPipe.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/21/25.
//

import Foundation
import Network

/// Raw framed binary pipe for the Packet Tunnel side.
/// Frame = [u32 little-endian length][payload]
final class DataPipe {
    private let q = DispatchQueue(label: "dataPipe.queue")
    private var listener: NWListener!
    private var conn: NWConnection?
    private var rx = Data()
    private let maxFrame = 8 * 1024 * 1024

    /// Packets arriving *from* the extension (to be forwarded to Java as JSON).
    var onPacketsFromExtension: (([Data]) -> Void)?

    init(port: UInt16 = 5502) throws {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "DataPipe", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: p)
        listener = try NWListener(using: params)

        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.conn?.cancel()
            self.conn = c
            self.rx.removeAll(keepingCapacity: false)

            c.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready:
                    self.readLoop()
                case .failed, .cancelled:
                    self.teardown()
                default:
                    break
                }
            }
            c.start(queue: self.q)
        }
    }

    func start() { listener.start(queue: q) }
    func cancel() { q.async { self.listener.cancel(); self.teardown() } }

    // To extension
    func sendPacketsToExtension(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        q.async { [weak self] in
            guard let self, let c = self.conn else { return }
            var out = Data()
            out.reserveCapacity(packets.reduce(0) { $0 + 4 + $1.count })
            for p in packets where !p.isEmpty {
                var lenLE = UInt32(p.count).littleEndian
                out.append(Data(bytes: &lenLE, count: 4))
                out.append(p)
            }
            c.send(content: out, completion: .contentProcessed { _ in })
        }
    }

    // From extension
    private func readLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.rx.append(data)
                self.processFrames()
            }
            if complete || err != nil {
                self.teardown()
                return
            }
            self.readLoop()
        }
    }

    private func processFrames() {
        var batch: [Data] = []
        while rx.count >= 4 {
            let lenLE = rx.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            let n = Int(lenLE)
            guard n > 0, n <= maxFrame else { teardown(); return }
            let need = 4 + n
            guard rx.count >= need else { break }
            let pkt = rx.subdata(in: 4..<need)
            rx.removeSubrange(0..<need)
            batch.append(pkt)
        }
        if !batch.isEmpty { onPacketsFromExtension?(batch) }
    }

    private func teardown() {
        let old = conn
        conn = nil
        old?.cancel()
        rx.removeAll(keepingCapacity: false)
    }
}

