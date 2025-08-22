//
//  HyperSpaceController.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/14/25.
//

import Foundation
import NetworkExtension

final class HyperSpaceController {
    @Published var status: NEVPNStatus = .invalid
    private(set) var manager: NETunnelProviderManager?
    private let providerBundleID = "com.whiteStar.HyperSpaceService.HyperSpaceTunnel"

    func loadOrCreate() async throws {
        // Load all managers; create if none
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        let mgr = all.first ?? NETunnelProviderManager()

        // Configure protocol
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = "HyperSpace"

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "HyperSpace Service"
        mgr.isEnabled = true

        // Save then reload to get a “live” manager instance
        try await mgr.saveToPreferences()
        let reloaded = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = reloaded.first ?? mgr

        observeStatus()
    }

    // MARK: Observe status
    @objc private func handleStatusChange(_ note: Notification) {
        status = manager?.connection.status ?? .invalid
    }

    private func observeStatus() {
        guard let conn = manager?.connection else { return }
        status = conn.status
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStatusChange(_:)),
            name: .NEVPNStatusDidChange,
            object: conn
        )
    }

    // MARK: Start/Stop

    /// Ensures we have the latest, enabled manager instance from disk.
    private func refreshEnabledManager() async throws -> NETunnelProviderManager {
        // If we already have one, reload it in place (pull latest flags)
        if let mgr = manager {
            try await mgr.loadFromPreferences()
            if !mgr.isEnabled {
                mgr.isEnabled = true
                try await mgr.saveToPreferences()
                try await mgr.loadFromPreferences()
            }
            manager = mgr
            return mgr
        }

        // Otherwise load from disk
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let mgr = all.first else {
            throw NSError(domain: "vpn", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No configuration found. Call loadOrCreate() first."])
        }
        // Make sure it’s enabled
        if !mgr.isEnabled {
            mgr.isEnabled = true
            try await mgr.saveToPreferences()
            try await mgr.loadFromPreferences()
        }
        manager = mgr
        return mgr
    }

    /// Start with custom options.
    func start(myIPv4Address: String,
               included: [String],
               excluded: [String],
               dnsMap: [String: [String]]) async throws {
        let mgr = try await refreshEnabledManager()
        guard let session = mgr.connection as? NETunnelProviderSession else {
            throw NSError(domain: "vpn", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No provider session"])
        }

        // Build strict [String:NSObject]
        let opts: [String:NSObject] = [
            "myIPv4Address": myIPv4Address as NSString,
            "includedRoutes": included as NSArray,
            "excludedRoutes": excluded as NSArray,
            "dnsMap": dnsMap as NSDictionary,
        ]

        do {
            try session.startTunnel(options: opts)
        } catch {
            throw wrapStartError(error)
        }
    }

    /// Start with no options.
    func start() async throws {
        let mgr = try await refreshEnabledManager()
        guard let session = mgr.connection as? NETunnelProviderSession else {
            throw NSError(domain: "vpn", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No provider session"])
        }
        do {
            try session.startTunnel(options: nil)
        } catch {
            throw wrapStartError(error)
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    // MARK: Provider messaging
    func send(_ dict: [String:Any]) async throws -> [String:Any] {
        let mgr = try await refreshEnabledManager()
        guard let session = mgr.connection as? NETunnelProviderSession else {
            throw NSError(domain:"vpn", code:3,
                          userInfo:[NSLocalizedDescriptionKey:"No provider session"])
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try await withCheckedThrowingContinuation { cont in
            do {
                try session.sendProviderMessage(data) { resp in
                    guard let resp else { cont.resume(returning: [:]); return }
                    let obj = (try? JSONSerialization.jsonObject(with: resp)) as? [String:Any] ?? [:]
                    cont.resume(returning: obj)
                }
            } catch { cont.resume(throwing: error) }
        }
    }

    // MARK: Error clarity
    private func wrapStartError(_ error: Error) -> NSError {
        let ns = error as NSError
        // Common NE errors worth surfacing
        let msg: String
        switch (ns.domain, ns.code) {
        case (NEVPNErrorDomain, NEVPNError.configurationInvalid.rawValue):
            msg = "Configuration invalid (often means not enabled or not saved)."
        case (NEVPNErrorDomain, NEVPNError.configurationDisabled.rawValue):
            msg = "Configuration is disabled. Enable it and save before starting."
        default:
            msg = ns.localizedDescription
        }
        return NSError(domain: "vpn.start", code: ns.code,
                       userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

