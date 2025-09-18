//
//  AppVersion.swift
//  HyperSpaceService
//
//  Created by Logan Miller on 9/17/25.
//

import Foundation

public struct AppVersion {
    // public static let appBuildVersion : String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    public static let appVersion : String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    public static var appSemanticVersion : String {
        guard let version = appVersion else {
            return "unknown"
        }
        return version
    }
}
