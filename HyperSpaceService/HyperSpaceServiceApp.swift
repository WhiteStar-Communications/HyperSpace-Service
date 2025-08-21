//
//  HyperSpaceServiceApp.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/14/25.
//

import SwiftUI
import AppKit

final class ServiceAppDelegate: NSObject, NSApplicationDelegate {
    private let vpn = HyperSpaceController()
    private var commandServer: CommandServer?
    private var pipe: DataPipe?
    private var dataServer: DataServer?

    private let installer = ServiceInstaller(
        extensionBundleIdentifier: "com.whiteStar.HyperSpaceService.HyperSpaceTunnel"
    )

    @State private var booted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless: no Dock, no menu bar (also set LSUIElement=YES in Info)
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
            let bp = try DataPipe(port: 5502)
            let ds = try DataServer(port: 5501)

            // Extension → App → Java (encode to JSON)
            bp.onPacketsFromExtension = { [weak ds] packets in
                ds?.sendOutgoingPackets(packets)
            }

            // Java → App → Extension (decode from JSON)
            ds.onInjectPackets = { [weak bp] packets in
                bp?.sendPacketsToExtension(packets)
            }

            bp.start()
            ds.start()
            pipe = bp
            dataServer = ds
        } catch {
            NSLog("Data wiring error: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up if you want
    }
}

@main
struct HyperSpaceServiceApp: App {
    @NSApplicationDelegateAdaptor(ServiceAppDelegate.self) var appDelegate

    // No WindowGroup! Provide a Settings scene (never shown) to satisfy SwiftUI.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
