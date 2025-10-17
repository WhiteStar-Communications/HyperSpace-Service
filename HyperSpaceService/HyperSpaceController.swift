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
import OSLog

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

public enum VPNApprovalState {
    case approved
    case notApproved
    case pending
    case removed
    case unknown
    
    public var rawValue: String {
        switch self {
            case .approved: return "vpnApproved"
            case .notApproved: return "vpnDenied"
            case .removed: return "vpnRemoved"
            case .pending,
                 .unknown: return "vpnPending"
        }
    }
}

final class HyperSpaceController {
    private(set) var manager: NETunnelProviderManager?
    public let tunnelEventClient = TunnelEventClient(port: 5600)

    public var vpnApprovalState: VPNApprovalState = .unknown
    private var configurationMonitor: Timer? = nil
    
    private let providerBundleID = "com.whiteStar.HyperSpaceService.HyperSpaceTunnel"
    public lazy var extensionInstaller = ServiceInstaller(extensionBundleIdentifier: providerBundleID)
    
    func createConfiguration(shouldSend: Bool) async throws {
        let mgr = NETunnelProviderManager()
        var errorDetected: VPNError?

        // Configure protocol
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = "HyperSpace Service"

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "HyperSpace Service"
        mgr.isEnabled = true

        // Save then reload to get an active manager instance
        mgr.saveToPreferences(completionHandler: { [weak self] (error) -> Void in
            guard let self = self else { return }
            if let error = error {
                switch(error.localizedDescription) {
                case "permission denied":
                    vpnApprovalState = .notApproved
                    if shouldSend {
                        tunnelEventClient.send([
                            "event": vpnApprovalState.rawValue
                        ])
                    }
                    errorDetected = VPNError.saveFailed(error)
                    return
                default:
                    break
                }
            } else {
                manager = mgr
                vpnApprovalState = .approved
                if shouldSend {
                    tunnelEventClient.send([
                        "event": vpnApprovalState.rawValue
                    ])
                }

                startConfigurationMonitor()
            }
        })
        
        if let error = errorDetected {
            throw VPNError.saveFailed(error)
        }
        
        let reloaded = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = reloaded.first ?? mgr
    }
    
    func getStatus() -> NEVPNStatus {
        guard let manager = manager else { return .disconnected }
        return manager.connection.status
    }
    
    func loadOrCreate(shouldSend: Bool) async throws {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        if !all.isEmpty {
            guard let mgr = all.first else {
                if vpnApprovalState == .pending { return }
                vpnApprovalState = .pending
                try await createConfiguration(shouldSend: shouldSend)
                return
            }
            
            manager = mgr
            vpnApprovalState = .approved
            if shouldSend {
                tunnelEventClient.send([
                    "event": vpnApprovalState.rawValue
                ])
            }
            startConfigurationMonitor()
        } else {
            if vpnApprovalState == .pending { return }
            vpnApprovalState = .pending
            try await createConfiguration(shouldSend: shouldSend)
        }
    }
    
    public func startConfigurationMonitor() {
        if configurationMonitor == nil {
            DispatchQueue.main.asyncAfter(deadline: .now(), execute: { [weak self] in
                self?.configurationMonitor = Timer.scheduledTimer(withTimeInterval: 3.0,
                                                  repeats: true) { _ in
                    self?.checkForValidConfiguration() { isValid in
                        if !isValid {
                            self?.vpnApprovalState = .removed
                            self?.tunnelEventClient.send([
                                "event": VPNApprovalState.removed.rawValue
                            ])
                            self?.configurationMonitor?.invalidate()
                            self?.configurationMonitor = nil
                        }
                    }
                }
            })
        }
    }
    
    func checkForValidConfiguration(completion: @escaping (Bool) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let _ = error {
                completion(false)
                return
            }

            guard let managers = managers else {
                completion(false)
                return
            }

            let exists = managers.contains { (manager: NETunnelProviderManager) in
                if let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol {
                    return tunnelProtocol.providerBundleIdentifier == "com.whiteStar.HyperSpaceService.HyperSpaceTunnel"
                }
                return false
            }

            completion(exists)
        }
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
        guard let manager = manager,
              let session = manager.connection as? NETunnelProviderSession else {
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
        guard let manager = manager,
              let session = manager.connection as? NETunnelProviderSession else {
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

    func send(_ dict: [String:Any]) async throws -> [String:Any] {
        guard let manager = manager,
              let session = manager.connection as? NETunnelProviderSession else {
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

