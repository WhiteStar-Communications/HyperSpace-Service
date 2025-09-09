//
//  DataEndpoint.swift
//  HyperSpaceTunnel
//
//  Created by Logan Miller on 9/9/25.
//

import Foundation
import NetworkExtension

final class DataEndpoint {
    private let fd: Int32
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dataEndpoint.queue")
    private(set) var lastPeer = sockaddr_storage()
    private(set) var lastPeerLen: socklen_t = 0

    init?(port: UInt16) {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        fd = sock

        // Non-blocking
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // Bind to 127.0.0.1:port
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else { close(fd); return nil }
    }

    var onDatagram: ((UnsafeBufferPointer<UInt8>, sockaddr_storage, socklen_t) -> Void)?

    func start() {
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source?.setEventHandler { [weak self] in
            guard let self else { return }
            var from = sockaddr_storage()
            var fromLen: socklen_t = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var buf = [UInt8](repeating: 0, count: 65536)

            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    buf.withUnsafeMutableBytes { raw in
                        recvfrom(self.fd, raw.baseAddress, raw.count, 0, sa, &fromLen)
                    }
                }
            }
            if n > 0 {
                self.lastPeer = from
                self.lastPeerLen = fromLen
                buf.withUnsafeBufferPointer { bp in
                    self.onDatagram?(UnsafeBufferPointer(start: bp.baseAddress, count: n), from, fromLen)
                }
            }
        }
        source?.setCancelHandler { [fd] in close(fd) }
        source?.resume()
    }

    func reply(_ bytes: [UInt8]) {
        guard lastPeerLen > 0 else { return }
        var peer = lastPeer
        withUnsafePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = bytes.withUnsafeBytes { raw in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa, lastPeerLen)
                }
            }
        }
    }
    
    func stop() { source?.cancel(); source = nil }
}
