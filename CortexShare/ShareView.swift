import SwiftUI
import CortexCore

/// The sheet: the link with its title, or the note's title, text and
/// pictures; *Add* or *Save* in the corner, so a page from Safari takes one
/// tap after choosing Cortex.
struct ShareView: View {
    @Bindable var model: ShareModel
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch model.content {
                case .loading:
                    ProgressView()
                case .link(let url):
                    linkForm(url)
                case .note:
                    noteForm
                case .nothing:
                    ContentUnavailableView(
                        "Nothing to save", systemImage: "square.and.arrow.down",
                        description: Text("Cortex takes web links, text and pictures."))
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) { model.save() }
                        .disabled(!canSave)
                }
            }
            .overlay {
                if let saved = model.saved {
                    Label(saved, systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .padding()
                        .glassEffect()
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.default, value: model.saved)
            .alert("Can't save it", isPresented: Binding { model.error != nil } set: { if !$0 { model.error = nil } }) {
                Button("OK") {}
            } message: {
                Text(model.error ?? "")
            }
        }
    }

    private var navigationTitle: String {
        switch model.content {
        case .link: "Reading List"
        case .note: "New Note"
        case .loading, .nothing: "Cortex"
        }
    }

    private var saveTitle: String {
        if case .link = model.content { return "Add" }
        return "Save"
    }

    private var canSave: Bool {
        switch model.content {
        case .link, .note: !model.isSaving
        case .loading, .nothing: false
        }
    }

    private func linkForm(_ url: URL) -> some View {
        Form {
            Section {
                TextField("Title", text: $model.title, axis: .vertical)
                Text(url.absoluteString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } footer: {
                Text("Added to your reading list when Cortex next runs, then synced to your Macs.")
            }
        }
    }

    private var noteForm: some View {
        Form {
            Section {
                TextField("Title", text: $model.title)
                if !model.text.isEmpty || model.pictures.isEmpty {
                    TextField("Text", text: $model.text, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($focused)
                }
            } footer: {
                Text("Into the inbox. Cortex syncs it to your Macs when it next runs.")
            }
            if !model.previews.isEmpty {
                Section(model.previews.count == 1 ? "Picture" : "\(model.previews.count) Pictures") {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(model.previews.indices, id: \.self) { index in
                                Image(uiImage: model.previews[index])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 96, height: 96)
                                    .clipShape(.rect(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
        }
    }
}
