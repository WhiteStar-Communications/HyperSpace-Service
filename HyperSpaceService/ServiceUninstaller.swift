//
//  ServiceUninstaller.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 9/17/25.
//

import Foundation
import NetworkExtension
import SystemExtensions

final class ServiceUninstaller: NSObject {
    private let extensionId: String

    init(extensionBundleIdentifier: String) {
        self.extensionId = extensionBundleIdentifier
    }

    func uninstallAll() async {
        do {
            try await stopVPNIfRunning()
            try await removeVPNConfiguration()
        } catch {
            print("VPN removal error: \(error)")
        }

        do {
            try await deactivateSystemExtension()
        } catch {
            print("System extension deactivation error: \(error)")
        }
        
        await MainActor.run {
            _ = self.moveAppToTrash()
        }
    }

    private func stopVPNIfRunning() async throws {
        try await withCheckedThrowingContinuation { cont in
            let mgr = NEVPNManager.shared()
            mgr.loadFromPreferences { loadErr in
                if let e = loadErr {
                    print("loadFromPreferences (stop) error: \(e)")
                    cont.resume()
                    return
                }

                mgr.isOnDemandEnabled = false
                mgr.saveToPreferences { _ in
                    if mgr.connection.status == .connected || mgr.connection.status == .connecting {
                        mgr.connection.stopVPNTunnel()
                    }
                    cont.resume()
                }
            }
        }
    }

    private func removeVPNConfiguration() async throws {
        try await withCheckedThrowingContinuation { cont in
            let mgr = NEVPNManager.shared()
            mgr.loadFromPreferences { loadErr in
                if let e = loadErr {
                    print("loadFromPreferences (remove) error: \(e)")
                }

                mgr.isOnDemandEnabled = false
                mgr.removeFromPreferences { removeErr in
                    if let e = removeErr {
                        print("removeFromPreferences error: \(e)")
                    }
                    cont.resume()
                }
            }
        }
    }

    private func deactivateSystemExtension() async throws {
        try await withCheckedThrowingContinuation { cont in
            let req = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: self.extensionId,
                queue: .main
            )
            let delegate = DeactivateDelegate { result in
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            DeactivateDelegateStore.shared.current = delegate   // retain until callback
            req.delegate = delegate
            OSSystemExtensionManager.shared.submitRequest(req)
        }
    }

    func removeVPNOnly() async {
        do {
            try await stopVPNIfRunning()
            try await removeVPNConfiguration()
        } catch {
            print("removeVPNOnly error: \(error)")
        }
    }

    func deactivateSystemExtensionOnly() async {
        do {
            try await deactivateSystemExtension()
        } catch {
            print("deactivateSystemExtensionOnly error: \(error)")
        }
    }
    

    @discardableResult
    func moveAppToTrash() -> Bool {
        guard let appURL = Bundle.main.bundleURL as URL? else {
            print("No bundleURL, nothing to trash.")
            return true
        }
        let parent = appURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir)
        let canWriteParent = parentExists && isDir.boolValue && FileManager.default.isWritableFile(atPath: parent.path)
        
        do {
            try FileManager.default.trashItem(at: appURL, resultingItemURL: nil)
            print("Moved app to Trash: \(appURL.path)")
            return true
        } catch {
            print("Could not move app to Trash: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Delegates

private final class DeactivateDelegateStore {
    static let shared = DeactivateDelegateStore()
    var current: DeactivateDelegate?
}

private final class DeactivateDelegate: NSObject, OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }
    
    enum Result { case success, failure(Error) }
    private let completion: (Result) -> Void
    init(completion: @escaping (Result) -> Void) { self.completion = completion }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        completion(.success)
        DeactivateDelegateStore.shared.current = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        completion(.failure(error))
        DeactivateDelegateStore.shared.current = nil
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("System extension deactivation needs user approval in System Settings.")
    }
}

