//
//  DataServer.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/14/25.
//

import Foundation
import Network

protocol DataServerDelegate: AnyObject {
    func dataServer(_ server: DataServer, didReceivePacket data: Data)
    func dataServerDidConnect(_ server: DataServer)
    func dataServerDidDisconnect(_ server: DataServer, error: Error?)
}

extension DataServerDelegate {
    func dataServerDidConnect(_ server: DataServer) {}
    func dataServerDidDisconnect(_ server: DataServer, error: Error?) {}
}

/// Data plane TCP server on loopback that streams framed packets.
/// Frame: [u32 little-endian packetLength][packetBytes]
final class DataServer {
    private var listener: NWListener!
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "data.server.io")
    private var rxBuffer = Data()
    private let maxFrame = 8 * 1024 * 1024

    weak var delegate: DataServerDelegate?

    init(port: UInt16 = 5501) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "DataServer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }

        // Bind to loopback only
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }

            // Replace any existing client
            self.conn?.cancel()
            self.rxBuffer.removeAll(keepingCapacity: false)

            self.conn = c
            c.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                    case .ready:
                        self.delegate?.dataServerDidConnect(self)
                        self.readLoop()
                    case .failed(let e):
                        self.delegate?.dataServerDidDisconnect(self,
                                                               error: e)
                    case .cancelled:
                        self.delegate?.dataServerDidDisconnect(self,
                                                               error: nil)
                    default:
                        break
                }
            }
            c.start(queue: self.queue)
        }
    }

    func start() {
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
        conn?.cancel()
        conn = nil
        rxBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - IO
    private func readLoop() {
        guard let c = conn else { return }
        c.receive(minimumIncompleteLength: 1,
                  maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.processFrames()
            }

            if isComplete || error != nil {
                self.conn?.cancel()
                return
            }
            self.readLoop()
        }
    }

    private func processFrames() {
        // Parse [lenLE][payload] frames; handle sticky/partial reads safely
        while rxBuffer.count >= 4 {
            let lenLE = rxBuffer.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            let frameLen = Int(lenLE)

            // Sanity checks
            if frameLen <= 0 || frameLen > maxFrame {
                // Corrupt stream: drop connection
                conn?.cancel()
                return
            }

            let needed = 4 + frameLen
            guard rxBuffer.count >= needed else { break }

            // Extract one frame
            let packet = rxBuffer.subdata(in: 4..<needed)
            rxBuffer.removeSubrange(0..<needed)

            delegate?.dataServer(self, didReceivePacket: packet)
        }
    }

    /// Send a framed packet to the connected client (e.g., for injection).
    func sendPacketToClient(_ bytes: Data) {
        guard let c = conn else { return }
        var lenLE = UInt32(bytes.count).littleEndian
        let hdr = Data(bytes: &lenLE, count: 4)
        c.send(content: hdr + bytes, completion: .contentProcessed { _ in })
    }

    /// Efficiently send a batch of packets in one write.
    func sendPacketsToClient(_ packets: [Data]) {
        guard let c = conn,
              !packets.isEmpty else { return }
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

