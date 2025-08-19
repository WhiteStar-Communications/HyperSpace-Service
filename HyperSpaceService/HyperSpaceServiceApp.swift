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
    @State private var cmd: CommandServer?
    @State private var data: DataServer?
    private let dataSink = DataSink()

    private let installer = ServiceInstaller(
        extensionBundleIdentifier: "com.whiteStar.HyperSpaceService.HyperSpaceTunnel"
    )

    @State private var booted = false

    var body: some Scene {
        WindowGroup {
            EmptyView()
                .onAppear {
                    guard !booted else { return }
                    booted = true

                    // 1) Ensure the system extension is installed/approved
                    installer.ensureInstalled()

                    // 2) Load/create VPN profile (prompts once)
                    Task { try? await vpn.loadOrCreate() }

                    // 3) Start TCP control/data servers
                    do {
                        let cs = try CommandServer(vpn: vpn,
                                                   port: 5500)
                        cs.start()
                        cmd = cs

                        let ds = try DataServer(port: 5501)
                        ds.delegate = dataSink
                        ds.start()
                        data = ds
                    } catch {
                        NSLog("Server init error: \(error.localizedDescription)")
                    }
                }
        }
    }
}
