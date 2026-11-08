import SwiftUI
import Speech
import AVFoundation
import UserNotifications
import AppKit
import Combine

struct Track: Hashable, Identifiable {
    var id: String { databaseID }
    let title: String
    let artist: String
    let playlist: String
    let databaseID: String
}
