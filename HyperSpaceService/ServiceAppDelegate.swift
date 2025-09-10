//
//  ServiceAppDelegate.swift
//  Created by Logan Miller on 8/14/25.
//
//  Copyright (c) 2025, WhiteStar Communications, Inc.
//  All rights reserved.
//  Licensed under the BSD 2-Clause License.
//  See LICENSE file in the project root for details.
//

import SwiftUI
import AppKit

final class ServiceAppDelegate: NSObject,
                                NSApplicationDelegate {
    private let vpn = HyperSpaceController()
    private var commandServer: CommandServer?
    private var tunnelEventServer: TunnelEventServer?

    private let installer = ServiceInstaller(
        extensionBundleIdentifier: "com.whiteStar.HyperSpaceService.HyperSpaceTunnel"
    )

    @State private var booted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        guard !booted else { return }
        booted = true

        installer.ensureInstalled()
        Task { try? await vpn.loadOrCreate() }

        // Command plane
        do {
            let cs = try CommandServer(vpn: vpn,
                                       port: 5500)
            cs.start()
            commandServer = cs
            
            let es = try TunnelEventServer(port: 5600)
            es.onEvent = { [weak commandServer] evt in
                // Wrap and forward to external application over the command plane
                var wrapped: [String: Any] = ["cmd": "event"]
                evt.forEach { wrapped[$0.key] = $0.value }
                commandServer?.sendEventToExternalApp(wrapped)
            }
            es.start()
            tunnelEventServer = es
        } catch {
            NSLog("Command server error: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Do nothing for now
    }
}

