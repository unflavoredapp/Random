//
// Brand: Tetherless · https://tetherless.dev
//  IPadnDownloadsView.swift
//  English Downloads Manager — structure from mengangs/ipadn DownloadsView (GPL-2.0).
//

import SwiftUI
import UniformTypeIdentifiers

struct DownloadsHomeView: View {
    @ObservedObject private var manager = IPadnDownloadManager.shared
    @State private var filter: IPadnDownloadFilter = .all
    @State private var term = ""
    @State private var editMode = false
    @State private var selection = Set<UUID>()
    @State private var showingActions = false
    @State private var pickingIPA = false
    @State private var addLink = false
    @State private var link = ""
    @State private var confirmingDelete = false
    @State private var shareURL: URL?

    private var filtered: [IPadnDownloadJob] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return manager.jobs.filter {
            filter.includes($0.status)
                && (q.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(q)
                    || $0.bundleID.localizedCaseInsensitiveContains(q)
                    || $0.version.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        IPadnBlurNavScroll(title: "Downloads") {
            downloadsTrailing
        } content: {
            if !manager.jobs.isEmpty {
                IPadnCapsuleSearch(
                    text: $term,
                    placeholder: "Search name, version, or Bundle ID",
                    onSubmit: {}
                )
            }

            if manager.waitingForWiFi {
                wifiBanner
            }

            if let storageError = manager.storageError, !storageError.isEmpty {
                Text(storageError).font(.footnote).foregroundStyle(.orange)
            }

            let visible = filtered
            if visible.isEmpty {
                emptyState
            } else {
                HStack {
                    Text("\(visible.count) item\(visible.count == 1 ? "" : "s")")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    if editMode {
                        Text("\(selection.count) selected")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                ForEach(visible) { job in
                    jobRow(job)
                    Divider().overlay(.white.opacity(0.08))
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .confirmationDialog("Add Download", isPresented: $showingActions, titleVisibility: .visible) {
            Button("Import IPA") { pickingIPA = true }
            Button("Download from Link") { addLink = true }
            if manager.jobs.contains(where: { [.running, .queued].contains($0.status) }) {
                Button("Pause All") { manager.pauseAll() }
            }
            if manager.jobs.contains(where: { $0.status == .paused || $0.status == .failed }) {
                Button("Resume All") { manager.resumeAll() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Download from Link", isPresented: $addLink) {
            TextField("HTTPS IPA URL", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") {
                if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    try? manager.enqueueURL(url)
                }
                link = ""
            }
            Button("Cancel", role: .cancel) { link = "" }
        } message: {
            Text("Enter an IPA package download link.")
        }
        .sheet(isPresented: $pickingIPA) {
            DocPicker(types: [UTType(filenameExtension: "ipa") ?? .data]) { urls in
                guard let url = urls.first else { return }
                try? manager.importFile(url)
            }
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .confirmationDialog(
            "Delete \(selection.count) tasks?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Tasks and Files", role: .destructive) {
                manager.remove(selection)
                selection.removeAll()
                editMode = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded packages will be deleted too.")
        }
        .safeAreaInset(edge: .bottom) {
            if editMode {
                editBar
            }
        }
    }

    private var downloadsTrailing: some View {
        HStack(spacing: 8) {
            Button(editMode ? "Done" : "Edit") {
                withAnimation {
                    editMode.toggle()
                    selection.removeAll()
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .disabled(manager.jobs.isEmpty)

            if editMode {
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selection.isEmpty ? .white.opacity(0.25) : .red.opacity(0.9))
                        .frame(width: 36, height: 36)
                }
                .disabled(selection.isEmpty)
                .accessibilityLabel("Delete selected")
            } else if !manager.jobs.isEmpty {
                Menu {
                    ForEach(IPadnDownloadFilter.allCases) { item in
                        Button {
                            filter = item
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                        }
                    }
                } label: {
                    Image(systemName: filter.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Filter downloads, currently \(filter.title)")
            }

            Button {
                showingActions = true
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Add Download")
        }
    }

    private var wifiBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash").foregroundStyle(.orange)
            Text("Waiting for Wi‑Fi")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private func jobRow(_ job: IPadnDownloadJob) -> some View {
        let live = manager.progress(for: job.id)
        HStack(alignment: .top, spacing: 14) {
            if editMode {
                Button {
                    if selection.contains(job.id) { selection.remove(job.id) }
                    else { selection.insert(job.id) }
                } label: {
                    Image(systemName: selection.contains(job.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selection.contains(job.id) ? TetherlessPalette.accent : .white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }

            CachedIcon(url: job.iconURL, side: 64, fallback: job.name)
                .task(id: job.id) {
                    guard job.iconURL == nil else { return }
                    await manager.backfillIcon(for: job.id)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(job.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                let meta = [
                    job.version.isEmpty ? nil : "v\(job.version)",
                    job.sizeLabel.isEmpty ? nil : job.sizeLabel
                ].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(.white.opacity(0.45))
                }

                statusLine(job, live: live)

                if [.running, .pausing, .paused].contains(job.status), job.expected > 0 || live.expected > 0 {
                    ProgressView(value: Double(max(job.downloaded, live.written)),
                                 total: Double(max(job.expected, live.expected, 1)))
                        .tint(TetherlessPalette.accent)
                }

                if let err = job.error, job.status == .failed {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if let play = FailurePlaybook.match(errorText: err) {
                        HStack(spacing: 8) {
                            Button(play.actionTitle) {
                                Task {
                                    await FailurePlaybook.run(play)
                                    if play.action == .acknowledgeFairPlay {
                                        manager.retry(job.id)
                                    }
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(TetherlessPalette.accent.opacity(0.9), in: Capsule())
                            .buttonStyle(.plain)

                            if play.action == .acknowledgeFairPlay {
                                Button("Open App Store") {
                                    AppStoreDecryptGuide.openAppStore()
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }

            Spacer(minLength: 0)

            if !editMode {
                trailingControl(job)
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            if job.status == .completed, let url = job.fileURL {
                Button("Install") { manager.install(job.id) }
                Button("Share") { shareURL = url }
            }
            if job.status == .running || job.status == .queued {
                Button("Pause") { manager.pause(job.id) }
            }
            if job.status == .paused || job.status == .failed {
                Button("Resume") { manager.resume(job.id) }
            }
            Button("Delete", role: .destructive) { manager.remove([job.id]) }
        }
    }

    @ViewBuilder private func statusLine(_ job: IPadnDownloadJob, live: IPadnDownloadProgress) -> some View {
        switch job.status {
        case .running:
            Text(job.progressLabel.isEmpty ? "Downloading…" : job.progressLabel)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        case .processing:
            if let pos = manager.companionQueuePosition(for: job.id), pos.total > 1 {
                Text(pos.index == 1
                      ? "Pushing to companion · \(pos.index) of \(pos.total)"
                      : "Queued for companion · \(pos.index) of \(pos.total)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            } else {
                Text("Pushing to companion…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            }
        case .paused:
            Text("Paused · \(job.progressLabel)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        case .completed:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TetherlessPalette.success)
        case .failed:
            Text(job.error?.isEmpty == false ? "Failed" : "Download failed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red.opacity(0.9))
        default:
            Text(job.status.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    @ViewBuilder private func trailingControl(_ job: IPadnDownloadJob) -> some View {
        switch job.status {
        case .running, .queued, .pausing, .processing:
            Button {
                manager.pause(job.id)
            } label: {
                Image(systemName: "pause.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pause")
        case .paused:
            Button("Resume") { manager.resume(job.id) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.14), in: Capsule())
                .buttonStyle(.plain)
        case .failed:
            Button("Retry") { manager.retry(job.id) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.14), in: Capsule())
                .buttonStyle(.plain)
        case .completed:
            HStack(spacing: 8) {
                Button("Install") { manager.install(job.id) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
                    .buttonStyle(.plain)
                if let url = job.fileURL {
                    Button {
                        shareURL = url
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.35))
            Text(manager.jobs.isEmpty ? "No downloads yet" : "No matching tasks")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(manager.jobs.isEmpty
                 ? "Tap Get on as many apps as you want — they stack here (download + decrypt only; sign later via Install). Store fetches run in parallel; companion pushes go one at a time."
                 : "Try another filter or clear the search.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            if manager.jobs.isEmpty {
                Button {
                    AppNav.shared.goSearch()
                } label: {
                    Text("Search Apps")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(TetherlessPalette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button("Show All") { filter = .all; term = "" }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var editBar: some View {
        HStack(spacing: 16) {
            let ids = Set(filtered.map(\.id))
            let all = !ids.isEmpty && ids.isSubset(of: selection)
            Button(all ? "Deselect All" : "Select All") {
                if all { selection.subtract(ids) } else { selection.formUnion(ids) }
            }
            .disabled(ids.isEmpty)
            Text("\(selection.count) selected")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Button("Delete Selected", systemImage: "trash", role: .destructive) {
                confirmingDelete = true
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .padding(.bottom, 56)
    }
}
