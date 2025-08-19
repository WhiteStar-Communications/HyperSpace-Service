//
//  DataPlaneClient.swift
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/19/25.
//

import Foundation
import Network

protocol DataPlaneClientDelegate: AnyObject {
    func dataClientDidConnect(_ client: DataPlaneClient)
    func dataClient(_ client: DataPlaneClient, didDisconnect error: Error?)
    func dataClient(_ client: DataPlaneClient, didReceivePacket packet: Data)
}

/// TCP client that connects to the host app's DataServer (127.0.0.1:5501).
/// Frame format: [u32 little-endian length][packet bytes]
public final class DataPlaneClient {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue: DispatchQueue

    private var conn: NWConnection?
    private var rxBuffer = Data()
    private var isStopping = false
    private var backoff: Double = 0.25
    private let backoffMax: Double = 5.0
    private let maxFrame = 8 * 1024 * 1024 // 8 MiB sanity cap

    weak var delegate: DataPlaneClientDelegate?

    init(host: String = "127.0.0.1", port: UInt16 = 5501, queue: DispatchQueue = .global(qos: .utility)) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.queue = queue
    }

    func start() {
        isStopping = false
        connect()
    }

    func stop() {
        isStopping = true
        conn?.cancel()
        conn = nil
        rxBuffer.removeAll(keepingCapacity: false)
    }

    // Send one packet (adds length prefix)
    func sendPacket(_ packet: Data) {
        var lenLE = UInt32(packet.count).littleEndian
        let hdr = Data(bytes: &lenLE, count: 4)
        sendRaw(hdr + packet)
    }

    // Send many packets efficiently (one write)
    func sendPackets(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        var out = Data()
        out.reserveCapacity(packets.reduce(0) { $0 + 4 + $1.count })
        for p in packets {
            var lenLE = UInt32(p.count).littleEndian
            out.append(Data(bytes: &lenLE, count: 4))
            out.append(p)
        }
        sendRaw(out)
    }

    // MARK: - Internals

    private func connect() {
        let c = NWConnection(host: host, port: port, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.backoff = 0.25
                self.delegate?.dataClientDidConnect(self)
                self.receiveLoop()
            case .failed(let e), .waiting(let e):
                self.delegate?.dataClient(self, didDisconnect: e)
                self.scheduleReconnect()
            case .cancelled:
                self.delegate?.dataClient(self, didDisconnect: nil)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func scheduleReconnect() {
        guard !isStopping else { return }
        let delay = backoff
        backoff = min(backoffMax, backoff * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.processFrames()
            }
            if isComplete || error != nil {
                self.conn?.cancel()
                return
            }
            self.receiveLoop()
        }
    }

    private func processFrames() {
        while rxBuffer.count >= 4 {
            let lenLE = rxBuffer.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            let frameLen = Int(lenLE)
            if frameLen <= 0 || frameLen > maxFrame {
                conn?.cancel()   // corrupt/hostile stream
                return
            }
            let needed = 4 + frameLen
            guard rxBuffer.count >= needed else { break }
            let packet = rxBuffer.subdata(in: 4..<needed)
            rxBuffer.removeSubrange(0..<needed)
            delegate?.dataClient(self, didReceivePacket: packet)
        }
    }

    private func sendRaw(_ data: Data) {
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }
}
