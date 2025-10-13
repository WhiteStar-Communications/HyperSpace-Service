//
//  HyperSpaceController.swift
//
//  Created by Logan Miller on 8/14/25.
//
//  Copyright (c) 2025, WhiteStar Communications, Inc.
//  All rights reserved.
//  Licensed under the BSD 2-Clause License.
//  See LICENSE file in the project root for details.
//

import Foundation
import NetworkExtension
import AppKit

final class HyperSpaceController {
    enum VPNError: LocalizedError {
        case saveFailed(Error)
        case startFailed(Error)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let err): return "Failed to save VPN configuration: \(err.localizedDescription)"
            case .startFailed(let err): return "Failed to start VPN: \(err.localizedDescription)"
            }
        }
    }
    
    public let installer = ServiceInstaller(
        extensionBundleIdentifier: "com.whiteStar.HyperSpaceService.HyperSpaceTunnel"
    )
    
    @Published var status: NEVPNStatus = .invalid
    private(set) var manager: NETunnelProviderManager?
    private let providerBundleID = "com.whiteStar.HyperSpaceService.HyperSpaceTunnel"
    public let tunnelEventClient = TunnelEventClient(port: 5600)
    public var errorDetected: VPNError?
    public var isVPNApproved: Bool = false
    
    func loadOrCreate() async throws {
        // reset errorDetected
        errorDetected = nil
        
        // Load all managers; create if none
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        let mgr = all.first ?? NETunnelProviderManager()

        // Configure protocol
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = "HyperSpace Service"

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "HyperSpace Service"
        mgr.isEnabled = true

        // Save then reload to get an active manager instance
        mgr.saveToPreferences(completionHandler: { [weak self] (error) -> Void in
            if let error = error {
                switch(error.localizedDescription) {
                case "permission denied":
                    self?.tunnelEventClient.send([
                        "event": "vpnDenied"
                    ])
                    self?.isVPNApproved = false
                    self?.errorDetected = VPNError.saveFailed(error)
                    return
                default:
                    break
                }
            } else {
                self?.tunnelEventClient.send([
                    "event": "vpnApproved"
                ])
                self?.isVPNApproved = true
            }
        })
        
        if let error = errorDetected {
            throw VPNError.saveFailed(error)
        }
        
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

    /// Ensures we have the latest, enabled manager instance from disk
    private func refreshEnabledManager() async throws -> NETunnelProviderManager {
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

        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let mgr = all.first else {
            throw NSError(domain: "vpn", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No configuration found. Call loadOrCreate() first."])
        }
        
        if !mgr.isEnabled {
            mgr.isEnabled = true
            try await mgr.saveToPreferences()
            try await mgr.loadFromPreferences()
        }
        manager = mgr
        return mgr
    }

    /// Start with custom options.
    func start(myIPv4Address: String) async throws {
        let mgr = try await refreshEnabledManager()
        guard let session = mgr.connection as? NETunnelProviderSession else {
            throw NSError(domain: "vpn", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No provider session"])
        }

        do {
            try session.startTunnel(options: ["myIPv4Address": myIPv4Address as NSString])
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
    
    func openLoginItemsAndExtensions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Error clarity
    private func wrapStartError(_ error: Error) -> NSError {
        let ns = error as NSError
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

