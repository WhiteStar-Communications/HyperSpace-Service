//
//  HyperSpaceServiceApp.swift
//  Created by Logan Miller on 8/14/25.
//

import SwiftUI
import AppKit

@main
struct HyperSpaceServiceApp: App {
    @NSApplicationDelegateAdaptor(ServiceAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
