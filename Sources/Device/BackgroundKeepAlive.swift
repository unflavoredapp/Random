//
//  BackgroundKeepAlive.swift
//  Keeps AirShare running while an install is in progress, so you can leave the app mid-install.
//
//  While at least one install workflow is active, a silent audio loop plays (UIBackgroundModes = audio,
//  mixes with whatever else is playing). While you're outside the app it also keeps one quiet banner
//  up to date ("Installing 4 Apps · 60% · Dynamic Lyrics") and posts "Installed …" when it's done.
//  Nothing runs when no install is active, so idle battery cost is zero.
//

import AVFoundation
import Combine
import MediaPlayer
import UIKit
import UserNotifications

@MainActor
final class BackgroundKeepAlive: ObservableObject {
    static let shared = BackgroundKeepAlive()
    static let enabledKey = "AirShare.keepAlive"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private static let bannerID = "airshare.install.progress"
    static let songKey = "AirShare.installSongFile"
    static let songTitleKey = "AirShare.installSongTitle"

    @Published private(set) var isHolding = false
    @Published private(set) var isPreviewing = false
    private var songPlayer: AVAudioPlayer?
    private var previewPlayer: AVAudioPlayer?

    private var holds = Set<String>()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var graphBuilt = false
    private var observers: [NSObjectProtocol] = []
    private var ticker: AnyCancellable?
    private var lastPercent = -1
    private var lastBody = ""
    private var idleSince: Date?
    private var userPaused = false          // paused from the lock screen: silence keeps the app alive instead
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var resumeAttempts = 0

    private init() {}

    // MARK: Install song (your own track instead of silence)

    struct SongError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var songURL: URL? {
        guard let name = UserDefaults.standard.string(forKey: songKey) else { return nil }
        let u = AppPaths.dir("install-song").appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Copies the picked file into AirShare's own storage and remembers it.
    func setSong(from picked: URL) throws {
        let fm = FileManager.default
        let dir = AppPaths.dir("install-song")
        let ext = picked.pathExtension.isEmpty ? "m4a" : picked.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("song-\(UUID().uuidString.prefix(8)).\(ext)")
        try fm.copyItem(at: picked, to: dest)
        guard (try? AVAudioPlayer(contentsOf: dest)) != nil else {
            try? fm.removeItem(at: dest)
            throw SongError(message: "That file can't be played. Try an MP3, M4A, WAV or AAC file.")
        }
        stopPreview()
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent != dest.lastPathComponent { try? fm.removeItem(at: f) }   // compare names: /var vs /private/var URLs differ and used to delete the new song too
        UserDefaults.standard.set(dest.lastPathComponent, forKey: Self.songKey)
        UserDefaults.standard.set(picked.deletingPathExtension().lastPathComponent, forKey: Self.songTitleKey)
    }

    func removeSong() {
        stopPreview()
        let fm = FileManager.default
        let dir = AppPaths.dir("install-song")
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
        UserDefaults.standard.removeObject(forKey: Self.songKey)
        UserDefaults.standard.removeObject(forKey: Self.songTitleKey)
    }

    /// Plays up to 15 seconds of the chosen song so you can check it.
    func togglePreview() {
        if isPreviewing { stopPreview(); return }
        guard !isHolding, let url = Self.songURL, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        p.prepareToPlay(); p.play()
        previewPlayer = p
        isPreviewing = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if self?.previewPlayer === p { self?.stopPreview() }
        }
    }

    func stopPreview() {
        guard isPreviewing || previewPlayer != nil else { return }
        previewPlayer?.stop(); previewPlayer = nil; isPreviewing = false
        if !isHolding { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    // MARK: Hold / release (called with every install workflow)

    func start(_ id: String) {
        guard Self.enabled else { return }
        let first = holds.isEmpty
        holds.insert(id)
        guard first else { return }
        stopPreview()
        beginAudio()
        lastPercent = -1; lastBody = ""; idleSince = nil; userPaused = false
        ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        isHolding = true
        InstallLiveActivity.shared.update(.init(title: "AirShare", detail: "Starting…", progress: 0.02, symbol: "arrow.down.circle.fill"))
    }

    func stop(_ id: String) {
        guard holds.remove(id) != nil, holds.isEmpty else { return }
        teardown(announceFinish: true)
    }

    private func teardown(announceFinish: Bool) {
        holds.removeAll()
        ticker = nil
        endNowPlaying()
        endAudio()
        finishLiveActivity(announce: announceFinish)
        isHolding = false
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.bannerID])
        guard announceFinish, UIApplication.shared.applicationState != .active else { return }
        let installer = NativeInstaller.shared
        // Batches and automatic updates post their own summary.
        guard !NativeBatchInstaller.shared.isRunning, !AppAutoUpdater.shared.busy,
              installer.stage == .done, let name = installer.job?.name else { return }
        post(id: "airshare.install.done", title: "Installed \(name)", body: "It's on your Home Screen.", quiet: false)
    }

    private func finishLiveActivity(announce: Bool) {
        let q = InstallQueue.shared
        let n = NativeInstaller.shared
        var failed = false
        var title = "Done"
        var detail = ""
        if !q.items.isEmpty {
            failed = q.failedCount > 0
            title = failed ? "\(q.doneCount) installed · \(q.failedCount) failed" : "Installed \(q.doneCount) app\(q.doneCount == 1 ? "" : "s")"
            detail = "All done"
        } else if case .failed(let m) = n.stage {
            failed = true; title = "Install failed"; detail = m
        } else if n.stage == .done, let name = n.job?.name {
            title = "Installed \(name)"; detail = "It's on your Home Screen."
        }
        InstallLiveActivity.shared.end(title: title, detail: detail, failed: failed)
    }

    // MARK: Silent audio

    private func beginAudio() {
        let session = AVAudioSession.sharedInstance()
        // With a song the session must NOT be mixable, otherwise iOS never shows the lock-screen player.
        try? session.setCategory(.playback, mode: .default, options: Self.songURL == nil ? [.mixWithOthers] : [])
        try? session.setActive(true)
        if !graphBuilt, let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            graphBuilt = true
        }
        playBackground()
        setupNowPlaying()
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }   // call / Siri / alarm finished
                Task { @MainActor in self?.recoverAudio() }
            },
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recoverAudio() }
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rebuildAudio() }
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
                let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor in
                    guard let self, !self.holds.isEmpty else { return }
                    if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                        self.pauseToSilence()           // headphones/Bluetooth gone: don't blast the speaker, keep the app alive
                    } else {
                        self.recoverAudio()
                    }
                }
            },
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recoverAudio() }
            },
        ]
    }

    /// Your song (looping) if you picked one, otherwise silence.
    private func playBackground() {
        if let url = Self.songURL, let p = try? AVAudioPlayer(contentsOf: url) {
            p.numberOfLoops = -1
            p.volume = 1
            p.prepareToPlay()
            if p.play() { songPlayer = p; return }
        }
        songPlayer = nil
        playSilence()
    }

    private func playSilence() {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100) else { return }
        buffer.frameLength = 44100                      // all zeros = silence
        if !engine.isRunning { try? engine.start() }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    /// After a phone call / Siri / alarm / route change took the audio session. Retries a few times,
    /// because iOS often refuses `setActive` for a moment right after an interruption ends.
    private func recoverAudio() {
        guard !holds.isEmpty else { return }
        resumeAttempts = 0
        attemptResume()
    }

    private func attemptResume() {
        guard !holds.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: Self.songURL == nil ? [.mixWithOthers] : [])
        do { try session.setActive(true) } catch {
            resumeAttempts += 1
            guard resumeAttempts < 6 else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.attemptResume()
            }
            return
        }
        if userPaused { playSilence() }
        else if let p = songPlayer { if !p.isPlaying { p.play() } ; updateNowPlaying() }
        else { playSilence() }
    }

    /// Media services crashed: rebuild everything from scratch.
    private func rebuildAudio() {
        guard !holds.isEmpty else { return }
        player.stop(); engine.stop()
        songPlayer = nil
        graphBuilt = false
        engine.reset()
        let paused = userPaused
        playBackgroundAfterReset(paused: paused)
    }

    private func playBackgroundAfterReset(paused: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: Self.songURL == nil ? [.mixWithOthers] : [])
        try? session.setActive(true)
        if let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            graphBuilt = true
        }
        if paused { playSilence() } else { playBackground() }
        updateNowPlaying()
    }

    // MARK: Lock screen / Control Center player

    private func setupNowPlaying() {
        guard Self.songURL != nil, remoteTargets.isEmpty else { updateNowPlaying(); return }
        let c = MPRemoteCommandCenter.shared()
        func add(_ cmd: MPRemoteCommand, _ handler: @escaping @MainActor (BackgroundKeepAlive) -> Void) {
            cmd.isEnabled = true
            let t = cmd.addTarget { [weak self] _ in
                Task { @MainActor in if let self { handler(self) } }
                return .success
            }
            remoteTargets.append((cmd, t))
        }
        add(c.playCommand) { $0.userResume() }
        add(c.pauseCommand) { $0.userPause() }
        add(c.togglePlayPauseCommand) { $0.userPaused ? $0.userResume() : $0.userPause() }
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard Self.songURL != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: UserDefaults.standard.string(forKey: Self.songTitleKey) ?? "AirShare",
            MPMediaItemPropertyArtist: installSubtitle(),
            MPNowPlayingInfoPropertyPlaybackRate: (userPaused ? 0.0 : 1.0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: songPlayer?.currentTime ?? 0,
        ]
        if let d = songPlayer?.duration, d > 0 { info[MPMediaItemPropertyPlaybackDuration] = d }
        if let img = UIImage(named: "aircore_logo") {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// "Installing Dynamic Lyrics · 60%" style line shown under the song title.
    private func installSubtitle() -> String {
        let q = InstallQueue.shared
        if q.isRunning { return q.compact }
        let n = NativeInstaller.shared
        if n.isActive { return "Installing \(Int((min(max(n.progress, 0), 1) * 100).rounded()))%" }
        return "AirShare"
    }

    private func userPause() {
        userPaused = true
        songPlayer?.pause()
        playSilence()              // keeps the app alive while the song is paused
        updateNowPlaying()
    }

    private func userResume() {
        userPaused = false
        player.stop()
        if let p = songPlayer { p.play() } else { playBackground() }
        updateNowPlaying()
    }

    /// Output device disappeared (headphones out): pause the song, stay alive on silence.
    private func pauseToSilence() { userPause() }

    private func endNowPlaying() {
        for (cmd, t) in remoteTargets { cmd.removeTarget(t) }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func endAudio() {
        player.stop()
        engine.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let fading = songPlayer {
            // Let the song fade out instead of cutting off.
            songPlayer = nil
            fading.setVolume(0, fadeDuration: 0.8)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                fading.stop()
                if self?.holds.isEmpty ?? true {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Progress banner (only while you're outside AirShare)

    private func tick() {
        guard !holds.isEmpty else { return }
        let installer = NativeInstaller.shared
        let batch = NativeBatchInstaller.shared
        let working = installer.isActive || batch.isRunning || AppAutoUpdater.shared.busy
            || DeviceInstallationManager.shared.pendingOperations > 0 || InstallQueue.shared.isRunning

        // Watchdog: if anything silenced us (and you didn't pause), bring the audio back.
        if let p = songPlayer { if !userPaused && !p.isPlaying { recoverAudio() } }
        else if !player.isPlaying || !engine.isRunning { recoverAudio() }
        if songPlayer != nil { updateNowPlaying() }

        // Safety net: if nothing is happening for two minutes, never keep the audio session alive for nothing.
        if working { idleSince = nil }
        else if let t = idleSince, Date().timeIntervalSince(t) > 120 { teardown(announceFinish: false); return }
        else if idleSince == nil { idleSince = Date() }

        let title: String, percent: Int, body: String, symbol: String
        var iconURL: URL?
        let queue = InstallQueue.shared
        if queue.isRunning {
            title = queue.title
            percent = Int((queue.fraction * 100).rounded())
            body = queue.summary
            iconURL = queue.current?.app.iconURL
            switch queue.current?.status {
            case .downloading?: symbol = "arrow.down.circle.fill"
            case .signing?: symbol = "signature"
            default: symbol = "square.and.arrow.down.fill"
            }
        } else if batch.isRunning {
            title = "Installing \(batch.items.count) App\(batch.items.count == 1 ? "" : "s")"
            percent = Int((batch.fraction * 100).rounded())
            let current = batch.items.first { $0.status == .installing }?.entry.name
            body = current.map { "\(percent)% · \($0)" } ?? "\(percent)%"
            iconURL = batch.items.first { $0.status == .installing }?.entry.iconURL
            symbol = "square.and.arrow.down.fill"
        } else if installer.isActive, let job = installer.job {
            title = "Installing \(job.name)"
            percent = Int((min(max(installer.progress, 0), 1) * 100).rounded())
            body = "\(percent)% · \(installer.stage.label.replacingOccurrences(of: "…", with: ""))"
            iconURL = SignedStore.shared.entries.first { $0.bundleID == job.bundleID }?.iconURL
            symbol = installer.stage == .installing ? "square.and.arrow.down.fill" : "arrow.up.circle.fill"
        } else { return }

        InstallLiveActivity.shared.update(.init(title: title, detail: body, progress: Double(percent) / 100, symbol: symbol, iconURL: iconURL))
        guard UIApplication.shared.applicationState != .active else { lastPercent = -1; return }

        guard percent != lastPercent || body != lastBody else { return }
        lastPercent = percent; lastBody = body
        if InstallLiveActivity.shared.isActive { return }      // the Live Activity already shows this
        post(id: Self.bannerID, title: title, body: body, quiet: true)
    }

    private func post(id: String, title: String, body: String, quiet: Bool) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if quiet {
            if #available(iOS 15.0, *) { c.interruptionLevel = .passive }
        } else {
            c.sound = .default
        }
        let request = UNNotificationRequest(identifier: id, content: c, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
