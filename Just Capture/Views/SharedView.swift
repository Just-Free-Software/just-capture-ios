import SwiftUI

/// The Shared tab: Drive folders other people shared by link, saved on this
/// phone for replay, with a badge when the sharer has added clips since.
struct SharedView: View {
    @Environment(SharedFolderStore.self) private var store

    @State private var linkText = ""
    @State private var playing: PlaybackTarget?
    @State private var folderToDelete: SharedFolder?
    @FocusState private var linkFieldFocused: Bool

    private struct PlaybackTarget: Identifiable {
        let id: String
        let title: String
    }

    private var linkFolderId: String? {
        GoogleDriveService.folderId(fromLink: linkText)
    }

    var body: some View {
        NavigationStack {
            List {
                addCard
                    .plainRow(top: 8)

                if let error = store.checkError {
                    NoticeBanner(
                        style: .warning,
                        systemImage: "exclamationmark.icloud",
                        title: "Couldn't check for new clips",
                        message: error,
                        onDismiss: { store.dismissCheckError() }
                    )
                    .plainRow()
                }

                Section {
                    if store.folders.isEmpty {
                        Text("Folders you open appear here and stay on this phone, so you can watch them again without downloading.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .card()
                            .plainRow()
                    } else {
                        ForEach(store.folders) { folder in
                            Button {
                                playing = PlaybackTarget(id: folder.id, title: folder.name)
                            } label: {
                                DriveFolderRow(
                                    title: folder.name,
                                    subtitle: subtitle(for: folder),
                                    newClipCount: folder.newClipCount
                                )
                            }
                            .buttonStyle(.plain)
                            .plainRow()
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash") {
                                    folderToDelete = folder
                                }
                                .tint(Theme.record)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Saved")
                        Spacer()
                        if store.isChecking {
                            ProgressView().controlSize(.mini).tint(.white)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            // Pull to refresh: one listing request per folder, skipping any
            // checked in the last 30 seconds.
            .refreshable { await store.checkForNewClips(minimumInterval: 30) }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Watch")
            .task { await store.checkForNewClips(minimumInterval: 5 * 60) }
            .sheet(item: $playing) { target in
                DrivePlaybackView(folderId: target.id, source: .publicLink, title: target.title)
            }
            .confirmationDialog(
                "Delete this folder?",
                isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
                titleVisibility: .visible,
                presenting: folderToDelete
            ) { folder in
                Button("Delete from This Phone", role: .destructive) {
                    store.remove(folder)
                    folderToDelete = nil
                }
            } message: { _ in
                Text("Removes the downloaded clips from this phone. The folder in Google Drive isn't affected, and you can add it again with its link.")
            }
        }
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a shared folder")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Paste a Google Drive folder link someone sent you. It must be shared as \"Anyone with the link\".")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 8) {
                TextField("drive.google.com/drive/folders/…", text: $linkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($linkFieldFocused)
                    .onSubmit(openLink)
                    .padding(10)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { linkText = first }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.roundedRectangle(radius: 10))
            }
            if !linkText.isEmpty && linkFolderId == nil {
                Text("That doesn't look like a Drive folder link.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
            Button(action: openLink) {
                Text("Download & Play")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .font(.subheadline.weight(.semibold))
            .disabled(linkFolderId == nil)
        }
        .card()
    }

    private func subtitle(for folder: SharedFolder) -> String {
        let count = folder.downloadedClipIds.count
        var parts = ["\(count) clip\(count == 1 ? "" : "s") saved"]
        if let checked = folder.lastCheckedAt {
            parts.append("checked \(checked.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private func openLink() {
        guard let folderId = linkFolderId else { return }
        linkFieldFocused = false
        let existing = store.folders.first { $0.id == folderId }
        playing = PlaybackTarget(id: folderId, title: existing?.name ?? "Shared Folder")
        linkText = ""
    }
}

private extension View {
    func plainRow(top: CGFloat = 6) -> some View {
        self
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
