//
//  DataPlaneClient.swift
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 8/19/25.
//

import Foundation
import Network

// MARK: - Delegate

public protocol DataPlaneClientDelegate: AnyObject {
    /// Connection reached .ready
    func dataPlaneClientDidConnect(_ c: DataPlaneClient)

    /// Connection closed or failed
    func dataPlaneClientDidDisconnect(_ c: DataPlaneClient, error: Error?)

    /// A single framed payload arrived
    func dataPlaneClient(_ c: DataPlaneClient, didReceivePacket packet: Data)

    /// Multiple frames arrived in one read (optional)
    func dataPlaneClient(_ c: DataPlaneClient, didReceivePackets packets: [Data])
}

public extension DataPlaneClientDelegate {
    func dataPlaneClientDidConnect(_ c: DataPlaneClient) {}
    func dataPlaneClientDidDisconnect(_ c: DataPlaneClient, error: Error?) {}
    func dataPlaneClient(_ c: DataPlaneClient, didReceivePacket packet: Data) {}
    func dataPlaneClient(_ c: DataPlaneClient, didReceivePackets packets: [Data]) {}
}

// MARK: - Client

public final class DataPlaneClient {

    public enum State: Equatable {
        case idle, connecting, ready, cancelled, failed
    }

    // Public
    public private(set) var state: State = .idle
    public weak var delegate: DataPlaneClientDelegate?

    // Config
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let autoReconnect: Bool
    private let maxFrame = 8 * 1024 * 1024

    // Internals
    private var conn: NWConnection?
    private let q = DispatchQueue(label: "dataplane.client.io")
    private var rx = Data()

    // Reconnect
    private var retryAttempt = 0
    private var reconnectPending = false

    public init(host: String = "127.0.0.1",
                port: UInt16 = 5501,
                autoReconnect: Bool = true)
    {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.autoReconnect = autoReconnect
    }

    // MARK: - Lifecycle

    public func start() {
        q.async { [weak self] in
            guard let self else { return }
            self.reconnectPending = false
            self.openConnection()
        }
    }

    public func stop() {
        q.async { [weak self] in
            guard let self else { return }
            self.autoReconnect ? (self.reconnectPending = false) : ()
            self.updateState(.cancelled)
            self.conn?.cancel()
            self.conn = nil
            self.rx.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - Send

    /// Send one framed payload.
    public func sendPacket(_ data: Data) {
        q.async { [weak self] in
            guard let self, let c = self.conn else { return }
            var lenLE = UInt32(data.count).littleEndian
            var out = Data(bytes: &lenLE, count: 4)
            out.append(data)
            c.send(content: out, completion: .contentProcessed { _ in })
        }
    }

    /// Send multiple frames efficiently in one write.
    public func sendPackets(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        q.async { [weak self] in
            guard let self, let c = self.conn else { return }
            var out = Data()
            out.reserveCapacity(packets.reduce(0) { $0 + 4 + $1.count })
            for p in packets {
                var lenLE = UInt32(p.count).littleEndian
                out.append(Data(bytes: &lenLE, count: 4))
                out.append(p)
            }
            c.send(content: out, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Internals

    private func openConnection() {
        if case .connecting = state { return }
        if case .ready = state { return }

        let params = NWParameters.tcp
        let c = NWConnection(host: host, port: port, using: params)
        conn = c
        updateState(.connecting)

        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.retryAttempt = 0
                self.updateState(.ready)
                self.delegateAsync { $0.dataPlaneClientDidConnect(self) }
                self.readLoop()

            case .failed(let err):
                self.updateState(.failed)
                self.cleanupAndMaybeReconnect(error: err)

            case .cancelled:
                self.updateState(.cancelled)
                self.cleanupAndMaybeReconnect(error: nil)

            default:
                break
            }
        }

        c.start(queue: q)
    }

    private func readLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.rx.append(data)
                self.processFrames()
            }

            if isComplete || err != nil {
                self.updateState(.failed)
                self.cleanupAndMaybeReconnect(error: err)
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
            guard n > 0, n <= maxFrame else {
                updateState(.failed)
                cleanupAndMaybeReconnect(error: NSError(domain: "DataPlaneClient",
                                                        code: 22,
                                                        userInfo: [NSLocalizedDescriptionKey: "Invalid frame length \(n)"]))
                return
            }
            let need = 4 + n
            guard rx.count >= need else { break }

            let pkt = rx.subdata(in: 4..<need)
            rx.removeSubrange(0..<need)
            batch.append(pkt)
        }

        if !batch.isEmpty {
            if batch.count == 1 {
                let p = batch[0]
                delegateAsync { $0.dataPlaneClient(self, didReceivePacket: p) }
            }
            delegateAsync { $0.dataPlaneClient(self, didReceivePackets: batch) }
        }
    }

    private func cleanupAndMaybeReconnect(error: Error?) {
        let old = conn
        conn = nil
        old?.cancel()
        delegateAsync { $0.dataPlaneClientDidDisconnect(self, error: error) }

        guard autoReconnect else { return }
        guard state != .cancelled else { return }

        retryAttempt = min(retryAttempt + 1, 5)
        let delay = pow(2.0, Double(retryAttempt - 1)) * 0.5
        if reconnectPending { return }
        reconnectPending = true
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reconnectPending = false
            self.openConnection()
        }
    }

    private func updateState(_ s: State) {
        state = s
    }

    private func delegateAsync(_ block: @escaping (DataPlaneClientDelegate) -> Void) {
        if let d = delegate {
            DispatchQueue.main.async { block(d) }
        }
    }
}
