import SwiftUI

/// Longer explanations of how the app works, opened from Settings.
struct SettingsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    section("Recording") {
                        row("video.fill", "Saved as you go",
                            "Your video is saved in short clips. Each one uploads to your Google Drive as soon as it's done, so what's uploaded stays safe even if you lose your phone.")
                        row("location.fill", "Your location",
                            "With Save location on, the app notes where you are when you start and after each clip. It's kept on your phone and in your Drive.")
                        row("cellularbars", "If your signal is bad",
                            "Each clip is saved on your phone first, so nothing is lost while you're offline. Uploads and emails that don't go through are tried again, waiting a little longer each time, up to 20 minutes between tries. When your connection comes back, they start again right away. Anything still waiting keeps trying after you leave the app, as long as your phone is on and the app hasn't been force-quit, though iOS decides when that happens, so it can take a while.")
                    }
                    section("What Can Stop a Recording") {
                        row("phone.fill", "Phone calls",
                            "While you're on a call, the recording keeps going without sound, and the sound comes back when the call ends. If you answer a call and it fills the screen, recording stops. After a call, check that you're still recording.",
                            tint: Theme.warning)
                        row("lock.iphone", "Leaving the app",
                            "Recording only works while Just Capture is on screen. Switching apps, going to the Home Screen, or locking your iPhone stops it. The screen stays on while you record, so it won't lock on its own. Clips you've already recorded still upload.",
                            tint: Theme.warning)
                    }
                    section("Notifying People") {
                        row("envelope.fill", "An email when you start",
                            "The people you add get an email from your Gmail with a link to your recording.")
                        row("text.bubble.fill", "What it says",
                            "When you started if Include start time is on, your message, and your location if it's on.")
                        row("exclamationmark.icloud.fill", "If your Drive fills up",
                            "They get an email when it's almost full, or once it's full. Just Capture keeps trying, so if space is freed or someone adds storage to your Google account, like whoever manages your family plan, the rest of your clips upload on their own. This works as long as your phone is on and the app hasn't been force-quit.")
                    }
                    section("Storage") {
                        row("iphone", "Clips stay on your phone",
                            "To free up space, delete old recordings in My Clips.")
                        row("checkmark.icloud.fill", "Your Drive is never touched",
                            "Just Capture never deletes anything from your Google Drive.")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("How It Works")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.leading, 16)
            VStack(alignment: .leading, spacing: 16, content: content)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .padding(.top, 8)
    }

    private func row(_ systemImage: String, _ title: String, _ text: String, tint: Color = Theme.accent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    SettingsHelpView()
}
