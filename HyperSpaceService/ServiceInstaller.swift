//
//  ServiceInstaller.swift
//
//  Created by Logan Miller on 8/14/25.
//
//  Copyright (c) 2025, WhiteStar Communications, Inc.
//  All rights reserved.
//  Licensed under the BSD 2-Clause License.
//  See LICENSE file in the project root for details.
//

import Foundation
import SystemExtensions

final class ServiceInstaller: NSObject, OSSystemExtensionRequestDelegate {
    public var isExtensionApproved: Bool = false
    public let tunnelEventClient = TunnelEventClient(port: 5600)
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

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension new: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if result.rawValue == 0 {
            tunnelEventClient.send([
                "event": "extensionApproved"
            ])
            isExtensionApproved = true
        }
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

