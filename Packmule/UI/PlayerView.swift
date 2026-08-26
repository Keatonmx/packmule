//
//  PlayerView.swift
//  Packmule
//
//  The full screen player: custom scrubber, skip buttons, speed, audio and
//  subtitle tracks, AirPlay, picture in picture, fill toggle, tap and double
//  tap gestures, auto hiding controls. Apple engine (AVPlayer); the FFmpeg
//  engine arrives as a second option later.
//

import SwiftUI
import AVFoundation
import AVKit

// MARK: - Engine

@MainActor
final class PlayerEngine: NSObject, ObservableObject {
    let player = AVPlayer()

    @Published var isPlaying = false
    @Published var buffering = true
    @Published var duration: Double = 0
    @Published var current: Double = 0
    @Published var rate: Float = 1
    @Published var failed: String?
    @Published var audioOptions: [AVMediaSelectionOption] = []
    @Published var legibleOptions: [AVMediaSelectionOption] = []
    @Published var selectedAudio: AVMediaSelectionOption?
    @Published var selectedLegible: AVMediaSelectionOption?

    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    func load(url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.allowsExternalPlayback = true

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let seconds = item.duration.seconds
                    self.duration = seconds.isFinite ? seconds : 0
                    self.loadTracks(for: item)
                case .failed:
                    self.failed = item.error?.localizedDescription ?? "This file wouldn't play"
                default:
                    break
                }
            }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = player.timeControlStatus == .playing
                self.buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite { self.current = seconds }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }
        player.playImmediately(atRate: rate)
    }

    private func loadTracks(for item: AVPlayerItem) {
        Task { [weak self] in
            let asset = item.asset
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            await MainActor.run {
                guard let self else { return }
                self.audibleGroup = audible
                self.legibleGroup = legible
                self.audioOptions = audible?.options ?? []
                self.legibleOptions = legible?.options ?? []
                if let audible {
                    self.selectedAudio = item.currentMediaSelection.selectedMediaOption(in: audible)
                }
                if let legible {
                    self.selectedLegible = item.currentMediaSelection.selectedMediaOption(in: legible)
                }
            }
        }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, current >= duration - 1 {
                seek(to: 0)
            }
            player.playImmediately(atRate: rate)
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        current = clamped
    }

    func skip(_ delta: Double) {
        seek(to: current + delta)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying {
            player.rate = newRate
        }
    }

    func selectAudio(_ option: AVMediaSelectionOption?) {
        guard let group = audibleGroup else { return }
        player.currentItem?.select(option, in: group)
        selectedAudio = option
    }

    func selectLegible(_ option: AVMediaSelectionOption?) {
        guard let group = legibleGroup else { return }
        player.currentItem?.select(option, in: group)
        selectedLegible = option
    }

    func teardown() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation = nil
        controlObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Layer host (also owns picture in picture)

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool
    let onPiPController: (AVPictureInPictureController?) -> Void

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.playerLayer.player = player
        view.backgroundColor = .black
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let pip = AVPictureInPictureController(playerLayer: view.playerLayer)
            context.coordinator.pip = pip
            onPiPController(pip)
        }
        return view
    }

    func updateUIView(_ view: LayerHostView, context: Context) {
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var pip: AVPictureInPictureController?
    }

    final class LayerHostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// The system AirPlay picker, tinted for the theme.
struct AirPlayButton: UIViewRepresentable {
    let tint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tint
        view.activeTintColor = tint
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

// MARK: - Player screen

struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    let request: PlayerRequest

    @StateObject private var engine = PlayerEngine()
    @State private var controlsVisible = true
    @State private var fillScreen = false
    @State private var scrubbing = false
    @State private var scrubTarget: Double = 0
    @State private var hideGeneration = 0
    @State private var pip: AVPictureInPictureController?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerView(player: engine.player, fill: fillScreen) { pip = $0 }
                .ignoresSafeArea()

            // Tap: toggle controls. Double tap left/right: skip.
            HStack(spacing: 0) {
                gestureZone { engine.skip(-10); poke() }
                gestureZone { engine.skip(10); poke() }
            }
            .ignoresSafeArea()

            if engine.buffering, engine.failed == nil {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
            }

            if let failed = engine.failed {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 34, weight: .light))
                        .foregroundColor(Palette.text55)
                    Text(failed)
                        .font(Typography.meta13)
                        .foregroundColor(Palette.textTertiary)
                        .multilineTextAlignment(.center)
                    SecondaryPill(title: "Close") { dismiss() }
                }
                .padding(.horizontal, 30)
            }

            if controlsVisible, engine.failed == nil {
                controls
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!controlsVisible)
        .onAppear {
            engine.load(url: request.url)
            UIApplication.shared.isIdleTimerDisabled = true
            scheduleHide()
        }
        .onDisappear {
            engine.teardown()
            model.playerClosed()
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    private func gestureZone(onDouble: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                ButtonHaptics.shared.tick()
                onDouble()
            }
            .onTapGesture {
                controlsVisible.toggle()
                if controlsVisible { scheduleHide() }
            }
    }

    // MARK: controls overlay

    private var controls: some View {
        VStack {
            topBar
            Spacer()
            centerControls
            Spacer()
            bottomBar
        }
        .background(
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                ButtonHaptics.shared.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.4))
                    .clipShape(Circle())
            }
            .buttonStyle(ScalePressStyle())

            Text(request.title)
                .font(Typography.cardTitle)
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            AirPlayButton(tint: .white)
                .frame(width: 34, height: 34)

            if AVPictureInPictureController.isPictureInPictureSupported() {
                overlayButton("pip.enter") {
                    pip?.startPictureInPicture()
                }
            }

            overlayButton(fillScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                fillScreen.toggle()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var centerControls: some View {
        HStack(spacing: 46) {
            Button {
                ButtonHaptics.shared.tap()
                engine.skip(-10)
                poke()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(.white)
            }
            .buttonStyle(ScalePressStyle())

            Button {
                ButtonHaptics.shared.tap()
                engine.togglePlay()
                poke()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 84, height: 84)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Circle())
            }
            .buttonStyle(ScalePressStyle())

            Button {
                ButtonHaptics.shared.tap()
                engine.skip(30)
                poke()
            } label: {
                Image(systemName: "goforward.30")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(.white)
            }
            .buttonStyle(ScalePressStyle())
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            scrubber

            HStack {
                Text(timeString(scrubbing ? scrubTarget : engine.current))
                    .font(Typography.mono11)
                    .foregroundColor(Palette.text70)
                Spacer()
                trackMenu
                speedMenu
                Spacer()
                Text(engine.duration > 0 ? timeString(engine.duration) : "  ")
                    .font(Typography.mono11)
                    .foregroundColor(Palette.text70)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let progress = engine.duration > 0
                ? (scrubbing ? scrubTarget : engine.current) / engine.duration
                : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                    .frame(height: scrubbing ? 8 : 5)
                Capsule().fill(theme.accent)
                    .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, progress)))),
                           height: scrubbing ? 8 : 5)
                Circle().fill(Color.white)
                    .frame(width: scrubbing ? 20 : 14, height: scrubbing ? 20 : 14)
                    .offset(x: geo.size.width * CGFloat(min(1, max(0, progress))) - (scrubbing ? 10 : 7))
                    .shadow(color: .black.opacity(0.4), radius: 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard engine.duration > 0 else { return }
                        scrubbing = true
                        let fraction = min(1, max(0, value.location.x / geo.size.width))
                        scrubTarget = Double(fraction) * engine.duration
                        poke()
                    }
                    .onEnded { _ in
                        guard engine.duration > 0 else { return }
                        engine.seek(to: scrubTarget)
                        scrubbing = false
                        poke()
                    }
            )
        }
        .frame(height: 30)
        .animation(.easeInOut(duration: 0.15), value: scrubbing)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                Button {
                    engine.setRate(Float(speed))
                } label: {
                    if engine.rate == Float(speed) {
                        Label(speedLabel(speed), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(speed))
                    }
                }
            }
        } label: {
            Text(speedLabel(Double(engine.rate)))
                .font(Typography.chip)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var trackMenu: some View {
        if !engine.audioOptions.isEmpty || !engine.legibleOptions.isEmpty {
            Menu {
                if !engine.legibleOptions.isEmpty {
                    Section("Subtitles") {
                        Button {
                            engine.selectLegible(nil)
                        } label: {
                            if engine.selectedLegible == nil {
                                Label("Off", systemImage: "checkmark")
                            } else {
                                Text("Off")
                            }
                        }
                        ForEach(Array(engine.legibleOptions.enumerated()), id: \.offset) { _, option in
                            Button {
                                engine.selectLegible(option)
                            } label: {
                                if engine.selectedLegible == option {
                                    Label(option.displayName, systemImage: "checkmark")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                    }
                }
                if engine.audioOptions.count > 1 {
                    Section("Audio") {
                        ForEach(Array(engine.audioOptions.enumerated()), id: \.offset) { _, option in
                            Button {
                                engine.selectAudio(option)
                            } label: {
                                if engine.selectedAudio == option {
                                    Label(option.displayName, systemImage: "checkmark")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
    }

    private func overlayButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            ButtonHaptics.shared.tap()
            action()
            poke()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.4))
                .clipShape(Circle())
        }
        .buttonStyle(ScalePressStyle())
    }

    // MARK: helpers

    private func dismiss() {
        model.playerRequest = nil
    }

    /// Any interaction restarts the auto hide countdown.
    private func poke() {
        controlsVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideGeneration += 1
        let generation = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            if generation == hideGeneration, engine.isPlaying, !scrubbing {
                controlsVisible = false
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
