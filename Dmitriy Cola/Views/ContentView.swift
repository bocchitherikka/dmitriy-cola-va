import SwiftUI
import Speech
import AVFoundation
import UserNotifications
import AppKit
import Combine

private struct AvailabilityAwarePulse: ViewModifier {
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.symbolEffect(.pulse, isActive: isActive)
        } else {
            content
        }
    }
}

struct ContentView: View {
    @StateObject private var controller = VoiceController()
    private var isRussian: Bool { Locale.current.language.languageCode?.identifier == "ru" }

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: controller.isListening ? "waveform" : "waveform.slash")
                    .font(.title2)
                    .foregroundStyle(controller.isListening ? .green : .secondary)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(isRussian ? "Голосовое управление музыкой" : "Dmitriy Cola")
                        .font(.headline.weight(.semibold))
                    Text(controller.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(controller.isListening
                       ? (isRussian ? "Остановить" : "Stop listening")
                       : (isRussian ? "Начать слушание" : "Start listening")) {
                    controller.isListening ? controller.stop() : controller.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.isListening ? .red : .accentColor)
                .disabled(controller.isBusy)
            }

            Spacer(minLength: 0)

            VStack(spacing: 16) {
                Image(systemName: controller.isListening ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 62, weight: .light))
                    .modifier(AvailabilityAwarePulse(isActive: controller.isListening))
                    .foregroundStyle(controller.isListening ? Color.green : Color.secondary)
                Text(controller.waitingForPlayCommand
                     ? (isRussian ? "Слушаю название трека…" : "Listening for a track…")
                     : (isRussian ? "Скажи «Дима, включи…»" : "Say “Dima, play…”"))
                    .font(.title2.weight(.semibold))
                Text(controller.liveTranscript.isEmpty
                     ? (isRussian ? "Распознанная речь появится здесь" : "Recognized speech will appear here")
                     : String(controller.liveTranscript.suffix(160)))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: 460, minHeight: 28)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))

            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 20) {
                nowPlayingCard
                    .frame(maxWidth: 340, alignment: .leading)
                Spacer(minLength: 0)
                listeningSettings
                    .frame(width: 240, alignment: .leading)
            }
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var listeningSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(isRussian ? "Громкость при прослушивании" : "Listening volume")
                .font(.caption.weight(.semibold))
            HStack {
                Text(isRussian ? "Приглушение" : "Duck level")
                Spacer()
                Text("\(Int(controller.duckVolume))%")
                    .monospacedDigit()
            }
            Slider(value: $controller.duckVolume, in: 1...25, step: 1)
            Text(isRussian ? "Русский и English · поиск в плейлистах" : "Russian and English · playlist search")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }

    private var nowPlayingCard: some View {
        HStack(spacing: 14) {
            Group {
                if let artwork = controller.currentArtwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(colors: [.purple.opacity(0.8), .blue.opacity(0.75), .pink.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.95))
                    }
                }
            }
            .frame(width: 74, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(isRussian ? "СЕЙЧАС ИГРАЕТ" : "NOW PLAYING")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(controller.currentTrack?.title ?? (isRussian ? "Ничего не играет" : "Nothing playing"))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(controller.currentTrack?.artist ?? (isRussian ? "Скажи название песни" : "Say a song title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
    }
}
