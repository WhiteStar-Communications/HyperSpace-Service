//
//  HyperSpaceController.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/14/25.
//

import Foundation
import NetworkExtension

@MainActor
final class HyperSpaceController: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    private(set) var manager: NETunnelProviderManager?
    private let providerBundleID = "com.whiteStar.HyperSpaceService.HyperSpaceTunnel"

    func loadOrCreate() async throws {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        let mgr = all.first ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = "HyperSpace"

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "HyperSpace VPN"
        mgr.isEnabled = true
        try await mgr.saveToPreferences()

        let reloaded = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = reloaded.first ?? mgr
        observeStatus()
    }

    @objc private func handleStatusChange(_ note: Notification) {
        status = manager?.connection.status ?? .invalid
    }

    private func observeStatus() {
        guard let conn = manager?.connection else { return }

        // Initial value
        status = conn.status

        // Selector-based API doesn't require a @Sendable closure
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleStatusChange(_:)),
                                               name: .NEVPNStatusDidChange,
                                               object: conn)
    }
    
    func start(myIPv4Address: String,
               included: [String],
               excluded: [String]) throws {
        guard let s = manager?.connection as? NETunnelProviderSession else {
            throw NSError(domain: "vpn", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No provider session"])
        }
        let opts: [String: Any] = [
            "myIPv4Address": myIPv4Address,
            "included": included,
            "excluded": excluded
        ]
        try s.startTunnel(options: opts as? [String : NSObject])
    }

    func start() throws {
        guard let s = manager?.connection as? NETunnelProviderSession else {
            throw NSError(domain: "vpn", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No provider session"])
        }
        try s.startTunnel(options: [] as? [String : NSObject])
    }
    
    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    func send(_ dict: [String:Any]) async throws -> [String:Any] {
        guard let s = manager?.connection as? NETunnelProviderSession else { throw NSError(domain:"vpn",
                                                                                           code:2) }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try await withCheckedThrowingContinuation { cont in
            do {
                try s.sendProviderMessage(data) { resp in
                    guard let resp else { cont.resume(returning: [:]); return }
                    let obj = (try? JSONSerialization.jsonObject(with: resp)) as? [String:Any] ?? [:]
                    cont.resume(returning: obj)
                }
            } catch { cont.resume(throwing: error) }
        }
    }
}
