//
// Brand: AppAssassin · https://fastdecrypt.ai
//  DecryptCompanionConsoleUIKit.swift
//  UIKit FastDecryptBot console for DecryptHelper (no SwiftUI in the helper path).
//

import Combine
import UIKit

/// Full-screen companion console used by the lean DecryptHelper binary.
final class DecryptCompanionConsoleViewController: UIViewController {
    private let companion = DecryptCompanionController.shared
    private var bag = Set<AnyCancellable>()
    private var didStart = false
    private var shareURL: URL?

    private let headerIcon = UIImageView()
    private let headerTitle = UILabel()
    private let appIcon = UIImageView()
    private let appName = UILabel()
    private let appVersion = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let logView = UITextView()
    private let shareButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 1)

        headerIcon.contentMode = .scaleAspectFill
        headerIcon.clipsToBounds = true
        headerIcon.layer.cornerRadius = 7
        headerIcon.translatesAutoresizingMaskIntoConstraints = false

        headerTitle.font = .preferredFont(forTextStyle: .headline)
        headerTitle.textColor = .white
        headerTitle.textAlignment = .center
        headerTitle.translatesAutoresizingMaskIntoConstraints = false

        appIcon.contentMode = .scaleAspectFill
        appIcon.clipsToBounds = true
        appIcon.layer.cornerRadius = 14
        appIcon.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        appIcon.translatesAutoresizingMaskIntoConstraints = false

        appName.font = .preferredFont(forTextStyle: .title3).bold()
        appName.textColor = .white
        appName.translatesAutoresizingMaskIntoConstraints = false

        appVersion.font = .preferredFont(forTextStyle: .subheadline)
        appVersion.textColor = UIColor.white.withAlphaComponent(0.55)
        appVersion.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.color = UIColor(red: 0.27, green: 0.56, blue: 0.97, alpha: 1)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        logView.isEditable = false
        logView.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        logView.textColor = UIColor.white.withAlphaComponent(0.85)
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.layer.cornerRadius = 16
        logView.clipsToBounds = true
        logView.translatesAutoresizingMaskIntoConstraints = false

        shareButton.setTitle("Share IPA with AppAssassin", for: .normal)
        shareButton.setTitleColor(.white, for: .normal)
        shareButton.backgroundColor = UIColor(red: 0.27, green: 0.56, blue: 0.97, alpha: 1)
        shareButton.layer.cornerRadius = 22
        shareButton.isHidden = true
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)

        let appCard = UIView()
        appCard.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        appCard.layer.cornerRadius = 18
        appCard.translatesAutoresizingMaskIntoConstraints = false

        let statusCard = UIView()
        statusCard.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        statusCard.layer.cornerRadius = 16
        statusCard.translatesAutoresizingMaskIntoConstraints = false
        statusCard.tag = 42

        // Top bar: always FastDecryptBot brand (never the target app name/icon).
        headerTitle.text = DecryptCompanionIdentity.companionDisplayName
        headerIcon.image = Self.loadBrandIcon()

        let headerRow = UIStackView(arrangedSubviews: [headerIcon, headerTitle])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerRow)
        view.addSubview(appCard)
        appCard.addSubview(appIcon)
        appCard.addSubview(appName)
        appCard.addSubview(appVersion)
        view.addSubview(statusCard)
        statusCard.addSubview(spinner)
        statusCard.addSubview(statusLabel)
        view.addSubview(shareButton)
        view.addSubview(logView)

        NSLayoutConstraint.activate([
            headerIcon.widthAnchor.constraint(equalToConstant: 28),
            headerIcon.heightAnchor.constraint(equalToConstant: 28),

            headerRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            headerRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            headerRow.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            headerRow.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            appCard.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 16),
            appCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            appCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            appIcon.leadingAnchor.constraint(equalTo: appCard.leadingAnchor, constant: 14),
            appIcon.topAnchor.constraint(equalTo: appCard.topAnchor, constant: 14),
            appIcon.bottomAnchor.constraint(equalTo: appCard.bottomAnchor, constant: -14),
            appIcon.widthAnchor.constraint(equalToConstant: 56),
            appIcon.heightAnchor.constraint(equalToConstant: 56),

            appName.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 14),
            appName.trailingAnchor.constraint(equalTo: appCard.trailingAnchor, constant: -14),
            appName.topAnchor.constraint(equalTo: appIcon.topAnchor, constant: 6),

            appVersion.leadingAnchor.constraint(equalTo: appName.leadingAnchor),
            appVersion.trailingAnchor.constraint(equalTo: appName.trailingAnchor),
            appVersion.topAnchor.constraint(equalTo: appName.bottomAnchor, constant: 4),

            statusCard.topAnchor.constraint(equalTo: appCard.bottomAnchor, constant: 14),
            statusCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            spinner.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            spinner.centerYAnchor.constraint(equalTo: statusCard.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 14),
            statusLabel.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -14),

            shareButton.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 12),
            shareButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            shareButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            shareButton.heightAnchor.constraint(equalToConstant: 44),

            logView.topAnchor.constraint(equalTo: shareButton.bottomAnchor, constant: 12),
            logView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        bind()
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        DecryptCompanionRuntime.bootstrapCompanionUI()
        Task { @MainActor in
            do {
                let url = try await DecryptCompanionRuntime.runEmbeddedDecrypt()
                if !companion.exportSentToHost {
                    shareURL = url
                    presentShare(url)
                }
            } catch {
                let text = error.localizedDescription
                companion.markFailed(text)
                if Self.shouldBounceToServer(text) {
                    companion.appendLog("On-device FairPlay failed — opening AppAssassin to finish on backup server…")
                    DecryptCompanionHandoff.requestServerFallback(reason: text)
                }
                presentFailureAlert(text)
            }
        }
    }

    private func bind() {
        companion.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
    }

    private func refresh() {
        // Brand chrome stays put; target identity lives in the app card only.
        headerTitle.text = DecryptCompanionIdentity.companionDisplayName
        headerIcon.image = Self.loadBrandIcon()
        appName.text = companion.displayName.isEmpty ? "App" : companion.displayName
        appVersion.text = companion.version.isEmpty ? "" : "Version \(companion.version)"
        statusLabel.text = companion.statusTitle
        if companion.busy {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        appIcon.image = companion.iconImage
            ?? Self.loadTargetIcon()
            ?? Self.loadBrandIcon()
        logView.text = companion.logLines.joined(separator: "\n")
        if !companion.logLines.isEmpty {
            let end = NSRange(location: max(0, logView.text.count - 1), length: 1)
            logView.scrollRangeToVisible(end)
        }
        shareButton.isHidden = !(companion.done && companion.finishedURL != nil)
        if companion.done, companion.finishedURL != nil {
            shareURL = companion.finishedURL
        }
    }

    @objc private func shareTapped() {
        guard let url = shareURL ?? companion.finishedURL else { return }
        presentShare(url)
    }

    private func presentShare(_ url: URL) {
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        present(av, animated: true)
    }

    private func presentFailureAlert(_ text: String) {
        let lower = text.lowercased()
        let alert = UIAlertController(title: "Decrypt failed", message: text, preferredStyle: .alert)
        if lower.contains("eperm") || lower.contains("fairplay needs") || lower.contains("live path")
            || lower.contains("license") || lower.contains("confirm keys") {
            alert.addAction(UIAlertAction(title: "Open App Store", style: .default) { _ in
                AppStoreDecryptGuide.openAppStore()
            })
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                AppStoreDecryptGuide.openSystemSettings()
            })
        }
        if Self.shouldBounceToServer(text) {
            alert.addAction(UIAlertAction(title: "Use backup server", style: .default) { _ in
                DecryptCompanionHandoff.requestServerFallback(reason: text)
            })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    private static func shouldBounceToServer(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("enomem")
            || t.contains("not enough memory")
            || t.contains("mremap")
            || t.contains("out of memory")
            || t.contains("jetsam")
            || t.contains("phone worker")
            || t.contains("unfairplay")
            || t.contains("bounce to")
    }

    private static func loadTargetIcon() -> UIImage? {
        let url = Bundle.main.bundleURL.appendingPathComponent("TargetIcon.png")
        return UIImage(contentsOfFile: url.path)
    }

    private static func loadBrandIcon() -> UIImage? {
        if let named = UIImage(named: DecryptCompanionIdentity.companionIconAsset) { return named }
        for name in ["AppIcon60x60@3x.png", "AppIcon60x60@2x.png", "iTunesArtwork@2x"] {
            let url = Bundle.main.bundleURL.appendingPathComponent(name)
            if let img = UIImage(contentsOfFile: url.path) { return img }
        }
        return TetherlessBrand.appIconImage()
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
