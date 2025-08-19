//
//  ServiceInstaller.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/14/25.
//

import Foundation
import SystemExtensions

final class ServiceInstaller: NSObject, OSSystemExtensionRequestDelegate {
    private let extensionId: String
    init(extensionBundleIdentifier: String) {
        self.extensionId = extensionBundleIdentifier
    }

    func ensureInstalled() {
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionId,
            queue: .main
        )
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    // MARK: - REQUIRED in newer SDKs: choose what to do when replacing an installed extension
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension new: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Simple policy: always replace with the new version
        return .replace
    }

    // MARK: - Other delegate callbacks (helpful but not strictly required)
    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        NSLog("SystemExtension result: \(result.rawValue)")
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFailWithError error: Error) {
        NSLog("SystemExtension install failed: \(error.localizedDescription)")
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        NSLog("SystemExtension needs user approval in System Settings > Privacy & Security")
    }

    func request(_ request: OSSystemExtensionRequest,
                 didInstallExtension extensionIdentifier: String,
                 replacingExtension existing: OSSystemExtensionProperties?) {
        NSLog("SystemExtension installed: \(extensionIdentifier)")
    }

    func request(_ request: OSSystemExtensionRequest,
                 didUpdateExtensionProperties properties: OSSystemExtensionProperties) {
        NSLog("SystemExtension updated: \(properties.bundleIdentifier)")
    }
}

