//
//  HyperSpaceServiceApp.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 8/14/25.
//

import SwiftUI

@main
struct HyperSpaceServiceApp: App {
    @StateObject private var vpn = HyperSpaceController()

    // Servers / pipe we keep alive for the app lifetime
    @State private var commandServer: CommandServer?
    @State private var dataServer: DataServer?
    @State private var pipe: DataPipe?

    // System extension installer
    private let installer = ServiceInstaller(
        extensionBundleIdentifier: "com.whiteStar.HyperSpaceService.HyperSpaceTunnel"
    )

    @State private var booted = false

    var body: some Scene {
        WindowGroup {
            // Headless window; no visible UI
            EmptyView()
                .onAppear {
                    guard !booted else { return }
                    booted = true

                    // 1) Ensure the system extension is installed/approved
                    installer.ensureInstalled()

                    // 2) Load/create VPN profile
                    Task { try? await vpn.loadOrCreate() }

                    // 3) Bring up the three sockets
                    startSockets()
                }
        }
    }

    // MARK: - Wiring

    private func startSockets() {
        do {
            // Control plane (JSON)
            let cs = try CommandServer(vpn: vpn, port: 5500)
            cs.start()
            commandServer = cs

            // Binary pipe for raw framed packets to/from the extension
            let dp = try DataPipe(port: 5502)
            // Packets coming UP from the extension (e.g., from TUN/libevent reads)
            dp.onPacketsFromExtension = { packets in
                // Forward to Java here
            }
            dp.start()
            pipe = dp

            // Data plane (JSON) for inbound packets FROM Java → tunnel
            let ds = try DataServer(port: 5501)
            // When Java calls {"op":"inject"...}, forward decoded packets into the extension:
            ds.onInjectPackets = { [weak dp] packets in
                dp?.sendPacketsToExtension(packets)
            }
            ds.start()
            dataServer = ds

        } catch {
            NSLog("Server init error: \(error.localizedDescription)")
        }
    }
}
