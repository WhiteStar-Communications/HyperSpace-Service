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

final class ServiceAppDelegate: NSObject, NSApplicationDelegate {
    private let vpn = HyperSpaceController()
    private var commandServer: CommandServer?
    private var dataServer: DataServer?
    private var tunnelEventServer: TunnelEventServer?
    private var dataPipe: DataPipe?

    private let installer = ServiceInstaller(
        extensionBundleIdentifier: "com.whiteStar.HyperSpaceService.HyperSpaceTunnel"
    )

    @State private var booted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless
        NSApp.setActivationPolicy(.prohibited)
        guard !booted else { return }
        booted = true

        installer.ensureInstalled()
        Task { try? await vpn.loadOrCreate() }

        // Control plane
        do {
            let cs = try CommandServer(vpn: vpn, port: 5500)
            cs.start()
            commandServer = cs
        } catch {
            NSLog("Command server error: \(error.localizedDescription)")
        }

        // Data (extension raw) -> Data (Java JSON)
        do {
            let ds = try DataServer(port: 5501)
            let dp = try DataPipe(port: 5502)

            // Extension → App → Java (encode to JSON)
            dp.onPacketsFromExtension = { [weak ds] packets in
                ds?.sendOutgoingPackets(packets)
            }

            // Java → App → Extension (decode from JSON)
            ds.onInjectPackets = { [weak dp] packets in
                dp?.sendPacketsToExtension(packets)
            }

            dp.start()
            ds.start()
            dataPipe = dp
            dataServer = ds
            
            let es = try TunnelEventServer(port: 5503)
            es.onEvent = { [weak commandServer] evt in
                // Wrap and forward to Java over the control socket
                var wrapped: [String: Any] = ["cmd": "event"]
                evt.forEach { wrapped[$0.key] = $0.value }
                commandServer?.sendEventToJava(wrapped)
            }
            es.start()
            tunnelEventServer = es
        } catch {
            NSLog("Data wiring error: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Do nothing for now
    }
}

