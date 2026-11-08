import SwiftUI
import Speech
import AVFoundation
import UserNotifications
import AppKit
import Combine

enum NotificationManager {
    static func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationBannerDelegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { allowed, error in
            if let error { NSLog("VoiceMusic notification authorization error: %@", error.localizedDescription) }
            if !allowed { NSLog("VoiceMusic notification permission was denied") }
        }
    }

    static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationBannerDelegate.shared
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                NSLog("VoiceMusic: notification permission is not granted; %@", body)
                return
            }
            deliver()
        }
    }
}

final class NotificationBannerDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationBannerDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
