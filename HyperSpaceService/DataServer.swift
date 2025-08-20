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

// MARK: - Server

/// Data plane TCP server (loopback) that streams framed packets.
/// Frame = [u32 little-endian length][packet bytes]
final class DataServer {
    weak var delegate: DataServerDelegate?

    private let queue = DispatchQueue(label: "data.server.io")
    private var listener: NWListener!
    private var conn: NWConnection?                 // single client (the Packet Tunnel)
    private var rxBuffer = Data()
    private let maxFrame = 8 * 1024 * 1024          // 8 MB safety cap

    // Small send buffer for packets enqueued before/while connection gets .ready
    private var pendingSends: [Data] = []
    private var isReady: Bool = false

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
            // Only one client (the extension) at a time; drop any previous.
            self.conn?.cancel()
            self.conn = c
            self.rxBuffer.removeAll(keepingCapacity: false)
            self.isReady = false

            c.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isReady = true
                    self.delegateMain { $0.dataServerDidConnect(self) }
                    self.flushPending()
                    self.readLoop()
                case .failed(let e):
                    self.finishConnection(error: e)
                case .cancelled:
                    self.finishConnection(error: nil)
                default:
                    break
                }
            }
            c.start(queue: self.queue)
        }
    }

    // MARK: Lifecycle

    func start() {
        listener.start(queue: queue)
    }

    func cancel() {
        queue.async {
            self.listener.cancel()
            self.finishConnection(error: nil)
        }
    }

    // MARK: Outgoing (App -> Extension)

    /// Send a single packet frame to the connected Packet Tunnel.
    func sendPacketToClient(_ packet: Data) {
        guard !packet.isEmpty else { return }
        queue.async {
            if !self.isReady || self.conn == nil {
                // queue until connection is .ready
                self.pendingSends.append(packet)
                return
            }
            self.sendFramed(packet)
        }
    }

    /// Send a batch of packets efficiently in one write.
    func sendPacketsToClient(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        queue.async {
            if !self.isReady || self.conn == nil {
                self.pendingSends.append(contentsOf: packets.filter { !$0.isEmpty })
                return
            }
            self.sendFramedBatch(packets)
        }
    }

    // MARK: Incoming (Extension -> App)

    private func readLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.processFrames()
            }

            if isComplete || error != nil {
                self.finishConnection(error: error)
                return
            }
            self.readLoop()
        }
    }

    private func processFrames() {
        var batch: [Data] = []
        while rxBuffer.count >= 4 {
            let lenLE = rxBuffer.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            let n = Int(lenLE)
            guard n > 0, n <= maxFrame else {
                // Corrupt stream; drop connection.
                self.finishConnection(error: NSError(domain: "DataServer", code: 22,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid frame length \(n)"]))
                return
            }
            let need = 4 + n
            guard rxBuffer.count >= need else { break }
            let pkt = rxBuffer.subdata(in: 4..<need)
            rxBuffer.removeSubrange(0..<need)
            batch.append(pkt)
        }

        if !batch.isEmpty {
            // Notify (single + batch)
            if batch.count == 1 {
                let p = batch[0]
                delegateMain { $0.dataServer(self, didReceivePacket: p) }
            }
            delegateMain { $0.dataServer(self, didReceivePackets: batch) }
        }
    }

    // MARK: Sending helpers

    private func sendFramed(_ payload: Data) {
        guard let c = conn else { return }
        var lenLE = UInt32(payload.count).littleEndian
        var out = Data(bytes: &lenLE, count: 4)
        out.append(payload)
        c.send(content: out, completion: .contentProcessed { _ in })
    }

    private func sendFramedBatch(_ packets: [Data]) {
        guard let c = conn else { return }
        var out = Data()
        out.reserveCapacity(packets.reduce(0) { $0 + 4 + $1.count })
        for p in packets where !p.isEmpty {
            var lenLE = UInt32(p.count).littleEndian
            out.append(Data(bytes: &lenLE, count: 4))
            out.append(p)
        }
        c.send(content: out, completion: .contentProcessed { _ in })
    }

    private func flushPending() {
        guard isReady, let _ = conn, !pendingSends.isEmpty else { return }
        // Coalesce pending into one write to reduce syscalls.
        sendFramedBatch(pendingSends)
        pendingSends.removeAll(keepingCapacity: false)
    }

    // MARK: Teardown

    private func finishConnection(error: Error?) {
        if let c = conn {
            c.cancel()
        }
        conn = nil
        isReady = false
        rxBuffer.removeAll(keepingCapacity: false)
        let queued = pendingSends.count
        pendingSends.removeAll(keepingCapacity: false)

        delegateMain { $0.dataServerDidDisconnect(self, error: error) }

        if queued > 0 {
            // If you want, you can requeue or drop; we drop by default.
            // (The tunnel will reconnect and you can resend if needed.)
        }
    }

    // MARK: Delegate helper

    private func delegateMain(_ block: @escaping (DataServerDelegate) -> Void) {
        guard let d = delegate else { return }
        DispatchQueue.main.async { block(d) }
    }
}
