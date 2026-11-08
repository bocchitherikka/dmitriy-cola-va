import SwiftUI
import Speech
import AVFoundation
import UserNotifications
import AppKit
import Combine

@main
struct VoiceMusicApp: App {
    init() {
        NotificationManager.prepare()
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let appIcon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = appIcon
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 900, height: 620)
    }
}
