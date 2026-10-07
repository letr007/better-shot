import AVKit
import SwiftUI

enum OnboardingDemo: String, CaseIterable, Identifiable {
    case screenshot, recording
    var id: String { rawValue }
    var title: String { self == .screenshot ? "Screenshots" : "Recordings" }
    var caption: String {
        self == .screenshot
            ? "Add arrows and text. Frame it with a background. Copy or export."
            : "Trim your recording. Zoom in on details. Export a video."
    }
    var imageDescription: String {
        self == .screenshot
            ? "A coastal photo with an arrow pointing to the path and a Walk this way label."
            : "A coastal video with a selected timeline range, zoomed in on the path."
    }
    func url(extension fileExtension: String, in bundle: Bundle) -> URL? {
        bundle.url(forResource: "\(rawValue)-demo", withExtension: fileExtension, subdirectory: "Onboarding")
    }
}

/// Bundled, silent demos. Still images remain useful without playback or network access.
struct OnboardingDemoView: View {
    let demo: OnboardingDemo
    var resourceBundle: Bundle = .main
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVPlayer?
    @State private var wantsPlayback = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                        .accessibilityLabel(L10n.format("%@ demonstration", L10n.string(demo.title)))
                } else if let url = demo.url(extension: "png", in: resourceBundle),
                          let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .accessibilityLabel(L10n.string(demo.imageDescription))
                } else {
                    Text(L10n.string(demo.imageDescription)).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(EditorChrome.border) }
            Text(L10n.string(demo.caption)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                wantsPlayback.toggle()
            } label: {
                Label(L10n.string(wantsPlayback ? "Close Demo" : "Watch Demo · 6 sec"),
                      systemImage: wantsPlayback ? "xmark.circle" : "play.circle")
            }
            .buttonStyle(EditorButtonStyle())
            .accessibilityLabel(wantsPlayback
                ? L10n.format("Close %@ demo", L10n.string(demo.title))
                : L10n.format("Watch %@ demo, 6 seconds", L10n.string(demo.title)))
            if let errorMessage {
                Text(L10n.string(errorMessage)).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: wantsPlayback) {
            guard wantsPlayback else { stop(); return }
            errorMessage = nil
            do {
                guard let url = demo.url(extension: "mp4", in: resourceBundle) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let asset = AVURLAsset(url: url)
                guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadCorruptFile) }
                guard !Task.isCancelled else { return }
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player.isMuted = true
                self.player = player
            } catch {
                guard !Task.isCancelled else { return }
                wantsPlayback = false
                errorMessage = "Couldn’t play the demo. You can try Watch Demo again or continue setup."
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            wantsPlayback = false
            stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            wantsPlayback = false
            stop()
            errorMessage = "Playback stopped. Try Watch Demo again or continue setup."
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            player?.pause()
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { wantsPlayback = false; stop() }
        }
        .onDisappear { wantsPlayback = false; stop() }
    }

    private func stop() {
        player?.pause()
        player = nil
    }
}
