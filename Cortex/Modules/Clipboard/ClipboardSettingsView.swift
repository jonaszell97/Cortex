import AppKit
import SwiftUI
import CortexCore
import UniformTypeIdentifiers

/// The Clipboard page's sections below its options: retention, sensitive
/// items, ignored apps and the Pastebot import.
struct ClipboardSettingsView: View {
    @Bindable var settings: ClipboardSettings
    let clipboard: ClipboardService

    @State private var itemCount: Int?
    @State private var confirmingClear = false
    @State private var pastebotFound: [PastebotImporter.Pasteboard]?
    @State private var message: String?

    var body: some View {
        Group {
            sections
        }
        .task { itemCount = await clipboard.itemCount() }
        .onChange(of: settings.indexSensitiveText) {
            Task { await clipboard.reindexSensitive() }
        }
        .onChange(of: settings.recognizeImageText) {
            if settings.recognizeImageText { clipboard.wakeIndexer() }
        }
        .onChange(of: settings.retentionPolicy) {
            Task {
                await clipboard.purge()
                itemCount = await clipboard.itemCount()
            }
        }
        .confirmationDialog("Clear the clipboard history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) {
                Task {
                    await clipboard.clearHistory()
                    itemCount = await clipboard.itemCount()
                }
            }
        } message: {
            Text("Pinned items are kept. This cannot be undone.")
        }
        .confirmationDialog(
            "Import from Pastebot?",
            isPresented: Binding(get: { pastebotFound != nil }, set: { if !$0 { pastebotFound = nil } })
        ) {
            Button("Import") { importPastebot() }
        } message: {
            Text(pastebotSummary)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {}
    }

    @ViewBuilder
    private var sections: some View {
        Section("History") {
            Picker("Keep items for", selection: $settings.retentionDays) {
                ForEach([1, 7, 30, 90, 365], id: \.self) { Text(days($0)).tag($0) }
                Text("Forever").tag(0)
            }
            Picker("Keep at most", selection: $settings.retentionMaxItems) {
                ForEach([500, 1_000, 2_000, 5_000, 10_000], id: \.self) { Text("\($0.formatted()) items").tag($0) }
                Text("Any number").tag(0)
            }
            Text("Pinned items are always kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Items in history") {
                HStack {
                    Text(itemCount.map { $0.formatted() } ?? "–")
                    Button("Clear History…") { confirmingClear = true }
                }
            }
        }

        Section("Sensitive items") {
            Picker("Keep sensitive items for", selection: $settings.sensitiveRetentionDays) {
                Text("Same as other items").tag(0)
                ForEach([1, 7, 30], id: \.self) { Text(days($0)).tag($0) }
            }
            Toggle("Include their text in search", isOn: $settings.indexSensitiveText)
            Toggle("Detect passwords and tokens", isOn: $settings.detectSensitiveText)
            Text("Items copied from password managers, or marked as concealed by the app that copied them, are recorded but masked. With detection on, so is copied text that looks like a password, an API token or a private key. Hold ⌥ in the palette to reveal them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Ignored apps") {
            ForEach(settings.ignoredBundleIDs, id: \.self) { bundleID in
                HStack {
                    if let icon = AppIconCache.shared.icon(for: bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(appName(bundleID))
                    Spacer()
                    Button {
                        settings.ignoredBundleIDs.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Add App…", action: addIgnoredApp)
            Text("Copies made while one of these apps is frontmost are not recorded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Import") {
            LabeledContent("Pastebot") {
                Button("Import History…", action: readPastebot)
            }
        }
    }

    private func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacing(".app", with: "") } ?? bundleID
    }

    private func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier, !settings.ignoredBundleIDs.contains(bundleID) {
                settings.ignoredBundleIDs.append(bundleID)
            }
        }
    }

    private var pastebotSummary: String {
        guard let pasteboards = pastebotFound else { return "" }
        let lines = pasteboards.map { pasteboard in
            let count = pasteboard.snapshots.filter { !$0.isEmpty }.count
            return pasteboard.isHistory ? "History: \(count) items" : "\(pasteboard.name): \(count) items (imported pinned)"
        }
        return (lines + ["Items already in the history are skipped."]).joined(separator: "\n")
    }

    private func readPastebot() {
        Task {
            do {
                let pasteboards = try await clipboard.readPastebot()
                if pasteboards.isEmpty {
                    message = "No Pastebot history found."
                } else {
                    pastebotFound = pasteboards
                }
            } catch {
                message = "Reading Pastebot's history failed: \(error.localizedDescription)"
            }
        }
    }

    private func importPastebot() {
        guard let pasteboards = pastebotFound else { return }
        pastebotFound = nil
        Task {
            do {
                let report = try await clipboard.importPastebot(pasteboards)
                itemCount = await clipboard.itemCount()
                message = "Imported \(report.inserted) items. \(report.alreadyPresent) were already in the history."
            } catch {
                message = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}
