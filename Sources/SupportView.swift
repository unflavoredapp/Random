import SwiftUI

/// Write to support and read replies. Premium tickets are flagged priority and shown to staff first.
struct SupportView: View {
    @ObservedObject private var support = SupportClient.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var subject = ""
    @State private var message = ""

    private var canSend: Bool {
        subject.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
            && message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 && !support.sending
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Subject", text: $subject)
                        .disabled(support.sending)
                    ZStack(alignment: .topLeading) {
                        if message.isEmpty {
                            Text("What's going wrong?").foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 4)
                        }
                        TextEditor(text: $message).frame(minHeight: 110).disabled(support.sending)
                    }
                    Button {
                        Task {
                            // The draft is only cleared once the server accepted it; on failure it stays so nothing is lost.
                            if await support.submit(subject: subject, message: message) { subject = ""; message = "" }
                        }
                    } label: {
                        HStack {
                            Text(support.sending ? "Sending\u{2026}" : "Send to support")
                            Spacer()
                            if support.sending { ProgressView() }
                        }
                    }
                    .disabled(!canSend)
                    if let n = support.notice { Text(n).font(.footnote).foregroundStyle(.green) }
                    if let e = support.sendError { Text(e).font(.footnote).foregroundStyle(.red) }
                } header: {
                    Text("New ticket")
                } footer: {
                    Text(support.isPremium
                         ? "Your tickets are marked priority and listed first for our team. Reply times can vary."
                         : "Premium tickets are listed first for our team. Reply times can vary for everyone.")
                }

                Section {
                    StateBanner(state: support.state) { Task { await support.load() } }
                    if support.state == .loaded && support.tickets.isEmpty {
                        Text("No tickets yet.").foregroundStyle(.secondary)
                    }
                    ForEach(support.tickets) { t in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(t.subject).font(.headline)
                                if t.priority {
                                    Text("PRIORITY").font(.caption2.weight(.heavy)).foregroundStyle(.black)
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(.orange, in: Capsule())
                                }
                                Spacer()
                                Text(t.statusText).font(.caption).foregroundStyle(t.status == "open" ? .yellow : .secondary)
                            }
                            Text(t.message).font(.subheadline).foregroundStyle(.secondary)
                            if let r = t.reply, !r.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Reply").font(.caption.weight(.semibold)).foregroundStyle(.green)
                                    Text(r).font(.subheadline)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    HStack {
                        Text("Your tickets")
                        if support.state == .refreshing { ProgressView().controlSize(.mini) }
                    }
                }
            }
            .navigationTitle("Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await support.load() }
            .refreshable { await support.load() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await support.refreshIfStale() } }   // a reply may have arrived while away
            }
        }
        .preferredColorScheme(.dark)
    }
}
