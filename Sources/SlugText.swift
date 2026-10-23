//
//  SlugText.swift
//  AirShare
//
//  Rich AirShare onboarding adapted from the AVX512 onboarding UI.
//  Identity remains local to AirShare through MDIDManager; no backend
//  registration is required to complete onboarding.
//

import SwiftUI
import UIKit
import AVFoundation
import ImageIO

// MARK: - Onboarding gate

@MainActor
final class Onboarding: ObservableObject {
    static let shared = Onboarding()
    private let key = "uzd_onboarded_v1"
    @Published var needsOnboarding: Bool

    private init() {
        needsOnboarding = !UserDefaults.standard.bool(forKey: key)
    }

    func complete() {
        UserDefaults.standard.set(true, forKey: key)
        needsOnboarding = false
    }
}

// MARK: - Phase

private enum AirShareOnboardingPhase: Equatable {
    case detecting
    case welcome
    case registering
    case success
    case error
}

// MARK: - Main onboarding

struct OnboardingView: View {
    var onDone: () -> Void

    @State private var phase: AirShareOnboardingPhase = .detecting
    @State private var deviceDescription = ""
    @State private var dotPhase = 0
    @State private var dotTimer: Timer?
    @State private var logoScale: CGFloat = 0.80
    @State private var logoOpacity = 0.0
    @State private var featuresOffset: CGFloat = 50
    @State private var featuresOpacity = 0.0
    @State private var buttonScale: CGFloat = 0.90
    @State private var buttonOpacity = 0.0
    @State private var errorMessage = ""
    @State private var confettiPieces: [AirShareConfettiPiece] = []

    private let maxRetries = 3
    @State private var attempts = 0

    private var accent: Color { Color(red: 1.0, green: 0.60, blue: 0.12) }   // onboarding is orange (AirShare brand)
    private var mdid: String { MDID.current }

    var body: some View {
        ZStack {
            Color(red: 0.027, green: 0.035, blue: 0.039).ignoresSafeArea()

            Group {
                switch phase {
                case .detecting:
                    detectingScreen
                case .welcome:
                    welcomeScreen
                case .registering:
                    loadingScreen
                case .success:
                    successScreen
                case .error:
                    errorScreen
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: phase)
        }
        .onAppear(perform: startDetection)
        .onDisappear { dotTimer?.invalidate() }
        .preferredColorScheme(AppTheme.shared.colorScheme)
    }

    // MARK: Detecting

    private var detectingScreen: some View {
        VStack(spacing: 30) {
            Spacer()

            ZStack {
                Circle()
                    .fill(accent.opacity(0.10))
                    .frame(width: 116, height: 116)
                Circle()
                    .strokeBorder(accent.opacity(0.28), lineWidth: 1.5)
                    .frame(width: 116, height: 116)
                Image(systemName: "touchid")
                    .font(.system(size: 54, weight: .ultraLight))
                    .foregroundStyle(accent)
            }

            VStack(spacing: 9) {
                Text("Scanning your device")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)

                Text(deviceDescription.isEmpty ? "Preparing your local AirShare identity…" : deviceDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == dotPhase ? accent : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .scaleEffect(i == dotPhase ? 1.35 : 1)
                        .animation(.easeInOut(duration: 0.3), value: dotPhase)
                }
            }

            Spacer()

            Text("AirShare · MRzefv · DELvEK.net")
                .font(.system(size: 12))
                .foregroundStyle(.gray.opacity(0.55))
                .padding(.bottom, 38)
        }
    }

    // MARK: Welcome

    private let passBG = Color(red: 0.027, green: 0.035, blue: 0.039)

    private var welcomeScreen: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        HStack(spacing: 12) {
                            brandMark(side: 40, radius: 12)
                                .scaleEffect(logoScale)
                            Text("AirShare")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Text("STEP 1 / 2")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .kerning(1.4)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .opacity(logoOpacity)
                    .padding(.top, 8)

                    (Text("Sign anything.\n").foregroundColor(.white)
                     + Text("Keep it local.").foregroundColor(accent))
                        .font(.system(size: 34, weight: .bold))
                        .lineSpacing(-2)
                        .padding(.top, 18)
                        .opacity(logoOpacity)

                    Text("Your signing environment lives on this device. No account needed.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 310, alignment: .leading)
                        .padding(.top, 8)
                        .opacity(logoOpacity)

                    devicePass
                        .padding(.top, 18)
                        .offset(y: featuresOffset)
                        .opacity(featuresOpacity)

                    VStack(spacing: 0) {
                        infoRow(icon: "clock.arrow.circlepath", title: "LOCAL HISTORY",
                                text: "Your signing history stays on this device.", tint: Color(red: 1, green: 0.84, blue: 0.62))
                        Divider().overlay(Color.white.opacity(0.14))
                        infoRow(icon: "bolt.fill", title: "LOCAL ZSIGN ENGINE",
                                text: "No signing request leaves this device.", tint: Color(red: 1, green: 0.84, blue: 0.62))
                        Divider().overlay(Color.white.opacity(0.14))
                        infoRow(icon: "checkmark.circle", title: "PROTECTED CERTIFICATES",
                                text: "Certificates remain protected by the existing certificate store.",
                                tint: Color(red: 0.6, green: 0.93, blue: 0.68), highlight: true)
                        Divider().overlay(Color.white.opacity(0.14))

                        HStack(alignment: .top, spacing: 0) {
                            linkTile(title: "AirShare.lol", url: "https://airshare.lol") {
                                brandMark(side: 32, radius: 9)
                            }
                            linkTile(title: "@FastDecryptBot", url: "https://t.me/FastDecryptBot", small: true) {
                                assetTile("fastdecrypt_logo", fallback: "scissors")
                            }
                            linkTile(title: "Donate", url: nil) {
                                symbolTile("bitcoinsign", Color(red: 0.2, green: 0.2, blue: 0.24))
                            }
                            linkTile(title: "DELvEK.NET", url: "https://delvek.net") {
                                assetTile("delvek_logo", fallback: "pawprint.fill")
                            }
                        }
                        .padding(.vertical, 8)
                        Divider().overlay(Color.white.opacity(0.14))

                        HStack(spacing: 6) {
                            Text("& even more…")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                            Text("No account required.")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 12)

                        Button(action: handleGetStarted) {
                            Text("Continue")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity).frame(height: 52)
                                .background(Color(white: 0.95), in: Capsule())
                        }
                        .scaleEffect(buttonScale)
                        .opacity(buttonOpacity)
                        .padding(.top, 10)
                    }
                    .padding(.top, 8)
                    .offset(y: featuresOffset)
                    .opacity(featuresOpacity)

                    Spacer(minLength: 8)
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 22)
                .frame(minHeight: geo.size.height)
            }
        }
        .background(
            ZStack {
                RadialGradient(colors: [accent.opacity(0.22), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 320)
                RadialGradient(colors: [Color.orange.opacity(0.14), .clear],
                               center: UnitPoint(x: 1.0, y: 0.25), startRadius: 0, endRadius: 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }

    private func brandMark(side: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let image = UIImage(named: "airshare_logo") {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let image = loadResourceImage("AirShareLogo", ext: "png") {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.06)
                    Image(systemName: "signature")
                        .font(.system(size: side * 0.45, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1))
        .shadow(color: Color.orange.opacity(0.35), radius: 12)
    }

    private var devicePass: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DEVICE PASS")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .kerning(1.6)
                        .foregroundStyle(.white.opacity(0.45))
                    Text(mdid)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .kerning(1.5)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: 8)
                Group {
                    if let phone = UIImage(named: "iphone_render") {
                        Image(uiImage: phone).resizable().scaledToFit()
                    } else {
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(accent)
                    }
                }
                .frame(width: 26, height: 44)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 10)

            HStack(spacing: 0) {
                Circle().fill(passBG).frame(width: 18, height: 18).offset(x: -9)
                PassDash().stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(height: 1)
                Circle().fill(passBG).frame(width: 18, height: 18).offset(x: 9)
            }

            HStack {
                HStack(spacing: 8) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                        .shadow(color: .green, radius: 5)
                    Text("Identity detected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.green)
                }
                Spacer(minLength: 8)
                Text(deviceDescription.replacingOccurrences(of: "iPhone · ", with: ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.063, green: 0.09, blue: 0.082), Color(red: 0.039, green: 0.055, blue: 0.05)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func infoRow(icon: String, title: String, text: String, tint: Color, highlight: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(highlight ? tint : .white)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }

    private func assetTile(_ name: String, fallback: String) -> some View {
        Group {
            if let img = UIImage(named: name) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack { Color(white: 0.12); Image(systemName: fallback).font(.system(size: 18, weight: .bold)).foregroundStyle(.white) }
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func symbolTile(_ name: String, _ bg: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg)
            Image(systemName: name)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder
    private func linkTile<Icon: View>(title: String, url: String?, small: Bool = false, @ViewBuilder icon: () -> Icon) -> some View {
        let content = VStack(spacing: 5) {
            icon()
            Text(title)
                .font(.system(size: small ? 10 : 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        if let url, let u = URL(string: url) {
            Link(destination: u) { content }
        } else {
            content
        }
    }

    // MARK: Loading

    private var loadingScreen: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(accent)

            Text("Preparing AirShare…")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))

            Text(mdid)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent.opacity(0.9))
                .tracking(2)
        }
    }

    // MARK: Success

    private var successScreen: some View {
        ZStack {
            RadialGradient(colors: [accent.opacity(0.20), .clear],
                           center: UnitPoint(x: 0.5, y: 0.28), startRadius: 0, endRadius: 300)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ForEach(confettiPieces) { piece in
                Circle()
                    .fill(piece.color)
                    .frame(width: 9, height: 9)
                    .scaleEffect(piece.scale)
                    .position(x: piece.x, y: piece.y)
            }

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("STEP 2 / 2")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .kerning(1.4)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, 26)

                ZStack {
                    Circle().strokeBorder(accent.opacity(0.18), lineWidth: 1).frame(width: 200, height: 200)
                    Circle().strokeBorder(accent.opacity(0.34), lineWidth: 1).frame(width: 156, height: 156)
                    Group {
                        if let mark = UIImage(named: "airshare_mark") {
                            Image(uiImage: mark).resizable().scaledToFit()
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 50, weight: .heavy))
                                .foregroundStyle(accent)
                        }
                    }
                    .frame(width: 124, height: 124)
                    .shadow(color: accent.opacity(0.55), radius: 26)
                }
                .padding(.top, 36)

                Text("You're all set.")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 26)

                Text("AirShare is ready to sign, package and install apps locally.")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("DEVICE PASS")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .kerning(1.6)
                            .foregroundStyle(.white.opacity(0.45))
                        Text(mdid)
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .kerning(1.2)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 8)
                    Group {
                        if let phone = UIImage(named: "iphone_render") {
                            Image(uiImage: phone).resizable().scaledToFit()
                        } else {
                            Image(systemName: "iphone.gen3")
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(accent)
                        }
                    }
                    .frame(width: 34, height: 58)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .background(Color(red: 0.05, green: 0.067, blue: 0.063), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .padding(.top, 30)

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Made by").foregroundStyle(.white.opacity(0.5))
                        Text("ᴹᴿ𝐙𝐄𝐅𝐯").foregroundStyle(.white)
                    }
                    .font(.system(size: 13))

                    HStack(spacing: 6) {
                        Text("Powered by").foregroundStyle(.white.opacity(0.5))
                        Text("DELvEK.net")
                            .fontWeight(.bold)
                            .foregroundStyle(accent)
                    }
                    .font(.system(size: 13))
                }
                .padding(.top, 26)

                Spacer(minLength: 20)

                Button(action: finish) {
                    Text("Continue to app")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(red: 0.10, green: 0.04, blue: 0.0))
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(accent, in: Capsule())
                        .shadow(color: accent.opacity(0.35), radius: 17, y: 10)
                }

            }
            .padding(.horizontal, 22)
        }
    }

    // MARK: Error

    private var errorScreen: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Setup Failed")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text(errorMessage)
                    .font(.system(size: 15))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if attempts < maxRetries {
                Button(action: startDetection) {
                    Text("Retry (\(attempts)/\(maxRetries))")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 200, height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(accent))
                }
            } else {
                Button(action: finish) {
                    Text("Continue Anyway")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 200, height: 56)
                        .background(RoundedRectangle(cornerRadius: 16).fill(accent))
                }
            }

            Spacer()
        }
    }

    // MARK: Actions

    private func startDetection() {
        attempts += 1
        dotTimer?.invalidate()
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: true) { _ in
            dotPhase = (dotPhase + 1) % 3
        }

        let device = UIDevice.current
        let bounds = UIScreen.main.nativeBounds
        deviceDescription = "\(device.model) · iOS \(device.systemVersion) · \(Int(bounds.width))×\(Int(bounds.height))"

        // The ADID is already created/persisted locally by MDIDManager.
        _ = MDID.current

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            dotTimer?.invalidate()
            withAnimation { phase = .welcome }
            animateWelcome()
        }
    }

    private func animateWelcome() {
        withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.05)) {
            logoScale = 1
            logoOpacity = 1
        }
        withAnimation(.spring(response: 0.8, dampingFraction: 0.8).delay(0.25)) {
            featuresOffset = 0
            featuresOpacity = 1
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.5)) {
            buttonScale = 1
            buttonOpacity = 1
        }
    }

    private func handleGetStarted() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation { phase = .registering }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            completeSetup()
        }
    }

    private func completeSetup() {
        guard !mdid.isEmpty else {
            errorMessage = "AirShare could not create a local device identity."
            withAnimation { phase = .error }
            return
        }

        withAnimation { phase = .success }
        generateConfetti()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onDone()
    }

    private func generateConfetti() {
        let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        confettiPieces = (0..<52).map { _ in
            AirShareConfettiPiece(
                x: .random(in: 0...w),
                y: -50,
                color: colors.randomElement() ?? accent,
                scale: .random(in: 0.5...1.3)
            )
        }
        for i in confettiPieces.indices {
            withAnimation(.easeIn(duration: .random(in: 1.8...3.5))) {
                confettiPieces[i].y = h + 100
            }
        }
    }

    private func loadResourceImage(_ name: String, ext: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Supporting rows

private struct PassDash: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

private struct AirShareConfettiPiece: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    let color: Color
    let scale: CGFloat
}

// MARK: - Looping animation

struct LoopingVideoPlayer: UIViewRepresentable {
    let resource: String
    let ext: String
    var muted: Bool = true

    func makeUIView(context: Context) -> UIView {
        let view = AirShareLoopingPlayerView()
        view.configure(resource: resource, ext: ext, muted: muted)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class AirShareLoopingPlayerView: UIView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()

    func configure(resource: String, ext: String, muted: Bool) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else { return }
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        queue.isMuted = muted
        queue.actionAtItemEnd = .none
        playerLayer.player = queue
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
        backgroundColor = .clear
        player = queue
        self.looper = looper
        queue.play()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

// MARK: - Lightweight GIF renderer

struct AnimatedImage: UIViewRepresentable {
    let frames: [UIImage]
    let duration: TimeInterval

    static func named(_ name: String) -> AnimatedImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var images: [UIImage] = []
        var total: TimeInterval = 0
        images.reserveCapacity(count)

        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            images.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.08
            total += max(delay, 0.02)
        }

        guard !images.isEmpty else { return nil }
        return AnimatedImage(frames: images, duration: total)
    }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.animationImages = frames
        view.animationDuration = duration
        view.image = frames.first
        view.startAnimating()
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}
}
