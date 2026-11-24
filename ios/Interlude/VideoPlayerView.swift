import AVKit
import SwiftUI
import UIKit

@MainActor
struct VideoPlayerView: View {
    let playback: Playback
    @ObservedObject var pictureInPicture: VideoPictureInPicture
    let fullscreen: Bool
    let toggleFullscreen: () -> Void
    let minimize: (() -> Void)?
    let openSettings: () -> Void
    let openSubtitles: () -> Void
    let playNext: () -> Void
    let roomControls: Bool
    let voiceAvailable: Bool
    let microphoneOn: Bool
    let microphoneBusy: Bool
    let toggleMicrophone: () -> Void
    let openRoom: () -> Void
    let changeSource: () -> Void
    let openEpisodes: (() -> Void)?
    let openInSight: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var awake = true
    @State private var locked = false
    @State private var remainingClock = false
    @State private var promptHovered = false
    @State private var hideControls: Task<Void, Never>?
    @State private var scrub: Double?
    @State private var scrubImage: CGImage?
    @State private var scrubPreviewTask: Task<Void, Never>?
    @State private var jump: Int = 0
    @State private var jumpTarget: Double?
    @State private var clearJump: Task<Void, Never>?
    @State private var hudText: String?
    @State private var clearHud: Task<Void, Never>?
    @State private var floatingReaction: WatchRoom.ReactionBurst?
    @State private var clearReaction: Task<Void, Never>?
    @State private var chatToast: WatchRoom.ChatToast?
    @State private var clearChatToast: Task<Void, Never>?

    private var chromeVisible: Bool { !locked && (awake || !playback.isPlaying || playback.finished || scrub != nil) }
    private var bottomInset: CGFloat { chromeVisible ? 92 : 16 }

    var body: some View {
        ZStack(alignment: .bottom) {
            VideoSurface(playback: playback, compatibilitySurface: playback.compatibility?.surface,
                         videoFill: playback.videoFill,
                         pictureInPicture: pictureInPicture,
                         locked: locked,
                         tap: toggleControls,
                         jump: jumpBy,
                         hover: wake,
                         pinch: { fill in
                             playback.toggleVideoFill(fill)
                             haptic(.light)
                             showHud(fill ? "Zoomed to fill" : "Original fit")
                         },
                         verticalDrag: handleVerticalDrag)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            if !playback.captionText.isEmpty {
                VideoCaptionLayer(text: playback.captionText, style: playback.captionStyle)
                    .padding(.bottom, chromeVisible ? 74 : 0)
                    .allowsHitTesting(false)
            }

            if !playback.error.isEmpty {
                VStack(spacing: 8) {
                    Text(playback.error).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                    HStack {
                        Button(playback.retrying ? "Opening…" : "Retry") { Task { await playback.retry() } }
                            .disabled(playback.retrying)
                        Button("Change source", action: changeSource)
                    }.buttonStyle(.bordered)
                }
                .padding(14).background(.black.opacity(0.86), in: .rect(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding(.horizontal, 20)
            }

            if playback.opening && playback.error.isEmpty {
                ProgressView().tint(.white).controlSize(.large).accessibilityLabel("Loading video")
                    .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
            }

            if playback.boosting {
                Label("2× speed", systemImage: "forward.fill").font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 14).allowsHitTesting(false)
            }

            if let hudText, !playback.boosting {
                Text(hudText).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 56).allowsHitTesting(false)
            }

            if locked && awake && !pictureInPicture.active {
                Button {
                    locked = false
                    haptic(.light)
                    wake()
                    showHud("Controls unlocked")
                } label: {
                    Label("Unlock controls", systemImage: "lock.open.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 28)
            }

            if chromeVisible && !pictureInPicture.active {
                Group {
                    VStack(spacing: 0) {
                        topBar
                        Spacer(minLength: 0)
                        transport
                    }
                    if playback.error.isEmpty && !playback.boosting && scrub == nil { primaryPlayback }
                }
                .transition(.opacity)
            }

            if let resumed = playback.resumedFrom, !locked, !pictureInPicture.active, playback.error.isEmpty {
                HStack(spacing: 10) {
                    Text("Resumed at \(Self.timeText(resumed))")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                    Button("Start over") {
                        haptic(.light)
                        playback.startOver()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.black.opacity(0.48), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.38), radius: 10, y: 4)
                .padding(.leading, 14).padding(.bottom, bottomInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }

            if let burst = floatingReaction, !pictureInPicture.active {
                Text("\(burst.emoji)  \(burst.author)")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 56).padding(.trailing, 16)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let toast = chatToast, !pictureInPicture.active {
                Button {
                    chatToast = nil
                    openRoom()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(toast.author).font(.caption2.bold()).foregroundStyle(Color.accentColor)
                        Text(toast.text).font(.caption).foregroundStyle(.white).lineLimit(2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
                    .background(Color.black.opacity(0.55), in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 260, alignment: .trailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 56).padding(.trailing, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let scrub {
                VStack(spacing: 6) {
                    if let scrubImage {
                        Image(decorative: scrubImage, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 176, height: 99)
                            .clipShape(.rect(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.28), lineWidth: 1))
                            .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
                    }
                    VStack(spacing: 2) {
                        Text(Self.timeText(scrub))
                            .font(.subheadline.monospacedDigit().weight(.bold))
                        if let chapter = chapterAt(scrub) {
                            Text(chapter.title).font(.caption2).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.82), in: Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false).accessibilityHidden(true)
            }

            if jump != 0 && scrub == nil {
                Label("\(abs(jump))s", systemImage: jump < 0 ? "gobackward" : "goforward")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.black.opacity(0.8), in: Capsule())
                    .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity,
                                       alignment: jump < 0 ? .leading : .trailing)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }

            if hasPrompt && !locked && !pictureInPicture.active && playback.error.isEmpty {
                prompts.padding(.trailing, 14).padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .foregroundStyle(.white)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: chromeVisible)
        .onAppear { if playback.isPlaying { wake() } }
        .onChange(of: playback.isPlaying) { _, playing in if playing { wake() } }
        .onChange(of: hasPrompt) { _, shown in if !shown { promptHovered = false } }
        .task(id: playback.resumedFrom) {
            guard playback.resumedFrom != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { playback.dismissResumePrompt() }
        }
        .onChange(of: playback.room.latestReaction) { _, burst in
            guard let burst else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { floatingReaction = burst }
            clearReaction?.cancel()
            clearReaction = Task {
                try? await Task.sleep(for: .milliseconds(2200))
                if !Task.isCancelled {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { floatingReaction = nil }
                }
            }
        }
        .onChange(of: playback.room.latestChat) { _, incoming in
            guard let incoming else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { chatToast = incoming }
            clearChatToast?.cancel()
            clearChatToast = Task {
                try? await Task.sleep(for: .milliseconds(4500))
                if !Task.isCancelled {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { chatToast = nil }
                }
            }
        }
        .onChange(of: scrub) { _, pos in
            scrubPreviewTask?.cancel()
            guard let pos else { scrubImage = nil; return }
            scrubPreviewTask = Task {
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled else { return }
                if let img = await playback.scrubThumbnail(at: pos), !Task.isCancelled {
                    scrubImage = img
                }
            }
        }
        .onDisappear { hideControls?.cancel(); clearJump?.cancel(); clearHud?.cancel(); clearReaction?.cancel(); clearChatToast?.cancel(); scrubPreviewTask?.cancel(); playback.endBoost() }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            if let minimize {
                chromeButton("chevron.down", "Minimize player", action: minimize)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(playback.selection?.media.title ?? playback.title)
                    .font(.subheadline.weight(.bold)).lineLimit(1)
                if let ep = playback.selection?.label {
                    Text(ep).font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if roomControls, !playback.room.friend.isEmpty {
                Button {
                    wake()
                    openRoom()
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text(playback.room.friend).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().stroke(.green.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if let openInSight {
                Button {
                    wake()
                    haptic(.light)
                    openInSight()
                } label: {
                    Label("InSight", systemImage: "sparkles")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(Color.black.opacity(0.42), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("InSight cast and scene info")
            }
            if let sleep = playback.sleepRemainingLabel {
                Button {
                    wake()
                    openSettings()
                } label: {
                    Label(sleep, systemImage: "moon.zzz.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sleep timer \(sleep)")
            }
            if let openEpisodes {
                chromeButton("list.bullet.rectangle", "Episodes", action: openEpisodes)
            }
            AirPlayRouteButton().frame(width: 40, height: 40)
            chromeButton(playback.videoFill ? "arrow.down.right.and.arrow.up.left" : "aspectratio",
                         playback.videoFill ? "Original fit" : "Fill screen") {
                playback.toggleVideoFill()
                haptic(.light)
                showHud(playback.videoFill ? "Zoomed to fill" : "Original fit")
            }
            chromeButton("lock.fill", "Lock controls") {
                locked = true
                haptic(.light)
                wake()
            }
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 12)
        .background(LinearGradient(colors: [.black.opacity(0.82), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var hasPrompt: Bool {
        playback.offersNextEpisode || playback.recapTarget != nil || playback.introTarget != nil
    }

    private var prompts: some View {
        HStack(spacing: 6) {
            if playback.offersNextEpisode {
                if !playback.finished || playback.nextCountdown != nil {
                    prompt(playback.finished ? "Cancel autoplay" : "Watch credits", primary: false, action: playback.cancelNext)
                }
                let seconds = playback.nextCountdown ?? 0
                prompt(seconds > 0 ? "Next episode in \(seconds)s" : "Next episode", action: playNext)
            } else {
                prompt(playback.recapTarget != nil ? "Skip recap" : "Skip intro") {
                    haptic(.medium)
                    playback.skipSegment()
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering in
            promptHovered = hovering
            if !hovering && awake { wake() }
        }
    }

    private func prompt(_ title: String, primary: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 2).frame(minHeight: 42)
                .foregroundStyle(Color.white)
                .background(primary ? Color.accentColor.blendedForVideo : Color.black.opacity(0.82), in: .rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private func jumpBy(_ seconds: Int) {
        guard playback.duration > 0, playback.error.isEmpty, !playback.boosting else { return }
        haptic(.light)
        let target = max(0, min(playback.duration, (jumpTarget ?? playback.time) + Double(seconds)))
        jumpTarget = target
        playback.action("seek", time: target)
        jump = jump.signum() == seconds.signum() ? jump + seconds : seconds
        clearJump?.cancel()
        clearJump = Task {
            try? await Task.sleep(for: .milliseconds(750))
            if !Task.isCancelled { jump = 0; jumpTarget = nil }
        }
        if chromeVisible { wake() }
    }

    private func handleVerticalDrag(isLeft: Bool, value: CGFloat) {
        let clamped = max(0, min(1, value))
        if isLeft {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.screen.brightness = clamped
            }
            showHud("Brightness \(Int((clamped * 100).rounded()))%")
        } else {
            playback.setVolume(Double(clamped))
            showHud("Volume \(Int((clamped * 100).rounded()))%")
        }
    }

    private func showHud(_ text: String) {
        hudText = text
        clearHud?.cancel()
        clearHud = Task {
            try? await Task.sleep(for: .milliseconds(1000))
            if !Task.isCancelled { hudText = nil }
        }
    }

    private func chapterAt(_ position: Double) -> VideoChapter? {
        playback.chapters.last { $0.start <= position }
    }

    private var primaryPlayback: some View {
        HStack(spacing: 24) {
            chromeButton("gobackward.10", "Back ten seconds") { jumpBy(-10) }
            Button {
                haptic(.light)
                wake()
                playback.action(playback.isPlaying && !playback.finished ? "pause" : "play")
            } label: {
                Image(systemName: playback.finished ? "arrow.counterclockwise" : playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold)).frame(width: 64, height: 64)
                    .background(.black.opacity(0.68), in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(playback.finished ? "Replay" : playback.isPlaying ? "Pause" : "Play")
            chromeButton("goforward.10", "Forward ten seconds") { jumpBy(10) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var customScrubber: some View {
        let total = max(1, playback.duration)
        let current = min(total, max(0, scrub ?? playback.time))
        let buffered = min(total, max(current, playback.bufferedTime))
        let segs = playback.timelineSegments

        return GeometryReader { geo in
            let width = max(1, geo.size.width)
            let progressW = CGFloat(current / total) * width
            let bufferedW = CGFloat(buffered / total) * width
            let trackH: CGFloat = scrub != nil ? 7 : 4

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: trackH)
                Capsule().fill(.white.opacity(0.45)).frame(width: bufferedW, height: trackH)
                if playback.duration > 0 {
                    ForEach([segs.recap, segs.intro, segs.credits].compactMap { $0 }, id: \.start) { seg in
                        let left = CGFloat(max(0, min(1, seg.start / total))) * width
                        let segW = max(3, CGFloat(max(0, min(1, (seg.end - seg.start) / total))) * width)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange.opacity(0.75))
                            .frame(width: segW, height: trackH)
                            .offset(x: left)
                    }
                }
                Capsule().fill(Color.accentColor).frame(width: progressW, height: trackH)
                if playback.duration > 0 {
                    ForEach(playback.chapters.dropFirst()) { chapter in
                        let tickX = CGFloat(max(0, min(1, chapter.start / total))) * width
                        Rectangle().fill(.black.opacity(0.7)).frame(width: 2, height: trackH + 1).offset(x: tickX)
                    }
                }
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .frame(width: scrub != nil ? 16 : 12, height: scrub != nil ? 16 : 12)
                    .offset(x: max(0, min(width - 12, progressW - (scrub != nil ? 8 : 6))))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard playback.duration > 0 else { return }
                        let fraction = max(0, min(1, value.location.x / width))
                        scrub = Double(fraction) * playback.duration
                        wake()
                    }
                    .onEnded { value in
                        guard playback.duration > 0 else { scrub = nil; return }
                        let fraction = max(0, min(1, value.location.x / width))
                        let target = Double(fraction) * playback.duration
                        playback.action("seek", time: target)
                        scrub = nil
                        wake()
                    }
            )
        }
        .frame(height: 28)
        .padding(.horizontal, 12)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { current }, set: { playback.action("seek", time: $0) }), in: 0...total) { Text("Position") }
        }
    }

    private var transport: some View {
        VStack(spacing: 0) {
            if roomControls {
                HStack(spacing: 6) {
                    ForEach(WatchRoom.reactionEmojis, id: \.self) { emoji in
                        Button {
                            haptic(.light)
                            wake()
                            playback.room.react(emoji)
                        } label: {
                            Text(emoji)
                                .font(.subheadline)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(.white.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Send \(emoji) reaction")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.bottom, 4)
            }
            customScrubber
            HStack(spacing: 0) {
                Button {
                    remainingClock.toggle()
                    wake()
                } label: {
                    let pos = scrub ?? playback.time
                    let left = remainingClock && playback.duration > 0 ? "-\(Self.timeText(max(0, playback.duration - pos)))" : Self.timeText(pos)
                    Text("\(left) / \(Self.timeText(playback.duration))")
                        .font(.system(.caption2, design: .monospaced)).monospacedDigit().lineLimit(1)
                        .padding(.leading, 12).padding(.vertical, 8)
                }.buttonStyle(.plain)
                if let chapter = chapterAt(scrub ?? playback.time) {
                    Text("· \(chapter.title)").font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1).padding(.leading, 5)
                }
                Spacer(minLength: 4)
                if roomControls {
                    chromeButton("person.2.wave.2", "Watch Together", action: openRoom)
                    if voiceAvailable {
                        chromeButton(microphoneOn ? "mic.fill" : "mic.slash", microphoneOn ? "Mute microphone" : "Turn on microphone",
                                     action: toggleMicrophone).disabled(microphoneBusy)
                    }
                }
                chromeButton("text.bubble", "What did they say?") {
                    haptic(.light)
                    showHud(playback.whatDidTheySay())
                }
                chromeButton("captions.bubble", "Subtitles", action: openSubtitles)
                    .foregroundStyle(playback.subtitlesEnabled ? Color.accentColor : Color.white)
                chromeButton("gearshape", "Playback settings", action: openSettings)
                if playback.compatibility == nil && pictureInPicture.possible {
                    chromeButton("pip.enter", "Picture-in-picture", action: pictureInPicture.start)
                }
                chromeButton(fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                             fullscreen ? "Exit fullscreen" : "Fullscreen", action: toggleFullscreen)
            }
        }
        .padding(.horizontal, 3)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.84)], startPoint: .top, endPoint: .bottom))
        .onHover { hovering in if hovering { wake() } }
    }

    private func chromeButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button {
            wake()
            action()
        } label: {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 42).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func toggleControls() {
        if locked { wake(); return }
        if chromeVisible && playback.isPlaying {
            hideControls?.cancel()
            awake = false
        } else { wake() }
    }

    private func wake() {
        awake = true
        hideControls?.cancel()
        hideControls = Task {
            try? await Task.sleep(for: .milliseconds(2600))
            if !Task.isCancelled && !promptHovered && scrub == nil { awake = false }
        }
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private static func timeText(_ time: Double) -> String {
        let seconds = Int(max(0, min(time, 86_400)))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = UIColor(Color.accentColor)
        picker.prioritizesVideoDevices = true
        picker.accessibilityLabel = "AirPlay and audio output"
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private extension Color {
    var blendedForVideo: Color {
        let base = UIColor(self)
        var red = CGFloat.zero, green = CGFloat.zero, blue = CGFloat.zero, alpha = CGFloat.zero
        guard base.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .black.opacity(0.85) }
        return Color(red: red * 0.42, green: green * 0.42, blue: blue * 0.42)
    }
}

@MainActor
final class VideoPictureInPicture: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var possible = false
    @Published private(set) var active = false
    var onRestore: (() -> Void)?
    private var controller: AVPictureInPictureController?
    private var availability: NSKeyValueObservation?
    private weak var layer: AVPlayerLayer?

    func attach(to layer: AVPlayerLayer) {
        guard self.layer !== layer, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        self.layer = layer
        availability = nil
        controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        availability = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self, weak layer] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor in
                if let self, self.layer === layer { self.possible = possible }
            }
        }
    }

    func start() {
        if controller?.isPictureInPicturePossible == true { controller?.startPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in active = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in active = false }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in active = false }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler complete: @escaping (Bool) -> Void) {
        Task { @MainActor in
            self.onRestore?()
            complete(true)
        }
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private weak var compatibilityView: UIView?

    func showCompatibility(_ surface: UIView?) {
        guard compatibilityView !== surface || (surface != nil && surface?.superview !== self) else { return }
        if compatibilityView?.superview === self { compatibilityView?.removeFromSuperview() }
        compatibilityView = surface
        if let surface {
            surface.frame = bounds
            surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(surface)
        }
    }
}

@MainActor
private struct VideoSurface: UIViewRepresentable {
    let playback: Playback
    let compatibilitySurface: UIView?
    let videoFill: Bool
    let pictureInPicture: VideoPictureInPicture
    let locked: Bool
    let tap: () -> Void
    let jump: (Int) -> Void
    let hover: () -> Void
    let pinch: (Bool) -> Void
    let verticalDrag: (Bool, CGFloat) -> Void

    func makeCoordinator() -> Input { Input(self) }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.videoLayer.player = playback.player
        view.videoLayer.videoGravity = videoFill ? .resizeAspectFill : .resizeAspect
        pictureInPicture.attach(to: view.videoLayer)
        let input = context.coordinator
        let press = UILongPressGestureRecognizer(target: input, action: #selector(Input.press(_:)))
        press.minimumPressDuration = 0.32
        press.allowableMovement = 14
        let touch = UITapGestureRecognizer(target: input, action: #selector(Input.tap))
        touch.require(toFail: press)
        let double = UITapGestureRecognizer(target: input, action: #selector(Input.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        double.delegate = input
        double.require(toFail: press)
        touch.require(toFail: double)
        let pinchGesture = UIPinchGestureRecognizer(target: input, action: #selector(Input.pinch(_:)))
        let panGesture = UIPanGestureRecognizer(target: input, action: #selector(Input.pan(_:)))
        panGesture.delegate = input
        view.addGestureRecognizer(press)
        view.addGestureRecognizer(touch)
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(pinchGesture)
        view.addGestureRecognizer(panGesture)
        view.addGestureRecognizer(UIHoverGestureRecognizer(target: input, action: #selector(Input.hover(_:))))
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        context.coordinator.surface = self
        let gravity: AVLayerVideoGravity = videoFill ? .resizeAspectFill : .resizeAspect
        if view.videoLayer.videoGravity != gravity { view.videoLayer.videoGravity = gravity }
        view.showCompatibility(compatibilitySurface)
    }

    @MainActor final class Input: NSObject, UIGestureRecognizerDelegate {
        var surface: VideoSurface
        private var dragStart: CGFloat = 0.5
        private var dragLeft = true

        init(_ surface: VideoSurface) { self.surface = surface }
        @objc func tap() { surface.tap() }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if surface.locked { return false }
            guard let view = gesture.view, view.bounds.width > 0 else { return false }
            if gesture is UITapGestureRecognizer {
                let fraction = touch.location(in: view).x / view.bounds.width
                return fraction < 0.4 || fraction > 0.6
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view else { return true }
            if surface.locked { return false }
            let v = pan.velocity(in: view)
            return abs(v.y) > abs(v.x) * 1.4
        }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard !surface.locked, let view = gesture.view else { return }
            surface.jump(gesture.location(in: view).x < view.bounds.midX ? -10 : 10)
        }

        @objc func hover(_ gesture: UIHoverGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed { surface.hover() }
        }

        @objc func press(_ gesture: UILongPressGestureRecognizer) {
            guard !surface.locked else { return }
            switch gesture.state {
            case .began:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                surface.playback.startBoost()
            case .ended, .cancelled, .failed:
                surface.playback.endBoost()
            default: break
            }
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard !surface.locked, gesture.state == .ended else { return }
            if gesture.scale > 1.08 { surface.pinch(true) }
            else if gesture.scale < 0.92 { surface.pinch(false) }
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard !surface.locked, let view = gesture.view, view.bounds.height > 0 else { return }
            if gesture.state == .began {
                dragLeft = gesture.location(in: view).x < view.bounds.midX
                if dragLeft {
                    dragStart = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.brightness ?? 0.5
                } else {
                    dragStart = CGFloat(min(1, surface.playback.filmVolume))
                }
            } else if gesture.state == .changed {
                let delta = -gesture.translation(in: view).y / (view.bounds.height * 0.65)
                surface.verticalDrag(dragLeft, dragStart + delta)
            }
        }
    }
}
