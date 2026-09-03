import AppKit
import RecCore
import SwiftUI

/// Chrome-style visual source picker: tabs for Window / App / Entire screen,
/// a grid of live thumbnails with app icons, click to select, Select to confirm.
@MainActor
final class SourcePickerModel: ObservableObject {
    enum Tab: String, CaseIterable { case window = "Window", app = "App", screen = "Entire screen" }
    enum Choice: Hashable {
        case window(CGWindowID), app(pid_t), screen(CGDirectDisplayID)
    }

    @Published var tab: Tab = .window
    @Published var choice: Choice?
    @Published private(set) var catalog: SourceCatalog?
    @Published private(set) var thumbnails: [Choice: CGImage] = [:]
    @Published private(set) var loading = false

    private var loadTask: Task<Void, Never>?

    func refresh() {
        loadTask?.cancel()
        loading = true
        thumbnails = [:]
        loadTask = Task {
            catalog = try? await SourceCatalog.load()
            await loadThumbnails()
            loading = false
        }
    }

    /// Thumbnails for the whole catalog, a few at a time, published as they
    /// arrive so the grid fills in progressively.
    private func loadThumbnails() async {
        guard let catalog else { return }
        let width = 360
        await withTaskGroup(of: (Choice, CGImage?).self) { group in
            var pending: [(Choice, () async -> CGImage?)] = []
            for w in catalog.windows { pending.append((.window(w.id), { await catalog.thumbnail(for: w, maxWidth: width) })) }
            for a in catalog.applications { pending.append((.app(a.id), { await catalog.thumbnail(for: a, maxWidth: width) })) }
            for d in catalog.displays { pending.append((.screen(d.id), { await catalog.thumbnail(for: d, maxWidth: width) })) }

            var iterator = pending.makeIterator()
            for _ in 0..<4 {   // concurrency limit
                if let (key, job) = iterator.next() { group.addTask { (key, await job()) } }
            }
            for await (key, image) in group {
                if Task.isCancelled { return }
                if let image { thumbnails[key] = image }
                if let (nextKey, job) = iterator.next() { group.addTask { (nextKey, await job()) } }
            }
        }
    }

    var selectedSource: CaptureSource? {
        guard let catalog, let choice else { return nil }
        switch choice {
        case .window(let id): return catalog.windows.first { $0.id == id }.map(CaptureSource.window)
        case .app(let pid): return catalog.applications.first { $0.id == pid }.map(CaptureSource.application)
        case .screen(let id): return catalog.displays.first { $0.id == id }.map(CaptureSource.screen)
        }
    }
}

struct SourcePickerView: View {
    @ObservedObject var model: SourcePickerModel
    let onSelect: (CaptureSource) -> Void
    let onCancel: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose what to record").font(.title2.weight(.semibold))
                Text("Window and App capture also limit the recorded system audio to that app.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Picker("", selection: $model.tab) {
                ForEach(SourcePickerModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(cards, id: \.choice) { card in
                        SourceCard(card: card, image: model.thumbnails[card.choice],
                                   selected: model.choice == card.choice)
                            .onTapGesture(count: 2) { model.choice = card.choice; confirm() }
                            .onTapGesture { model.choice = card.choice }
                    }
                }
                .padding(20)
                if cards.isEmpty {
                    Text(model.loading ? "Loading…" : "Nothing to show here.")
                        .foregroundStyle(.secondary).padding(40)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()
            HStack {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Select") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedSource == nil)
            }
            .padding(16)
        }
        .frame(minWidth: 860, minHeight: 600)
        .onAppear { if model.catalog == nil { model.refresh() } }
    }

    private func confirm() {
        if let source = model.selectedSource { onSelect(source) }
    }

    private struct Card {
        let choice: SourcePickerModel.Choice
        let title: String
        let subtitle: String
        let icon: NSImage?
    }

    private var cards: [Card] {
        guard let catalog = model.catalog else { return [] }
        switch model.tab {
        case .window:
            return catalog.windows.map {
                Card(choice: .window($0.id), title: $0.title.isEmpty ? $0.appName : $0.title,
                     subtitle: $0.appName, icon: appIcon(pid: $0.processID))
            }
        case .app:
            return catalog.applications.map {
                Card(choice: .app($0.id), title: $0.name,
                     subtitle: "\($0.windowCount) window\($0.windowCount == 1 ? "" : "s") — audio limited to this app",
                     icon: appIcon(pid: $0.id))
            }
        case .screen:
            return catalog.displays.map {
                Card(choice: .screen($0.id), title: $0.name, subtitle: "Everything on this display",
                     icon: NSImage(systemSymbolName: "display", accessibilityDescription: nil))
            }
        }
    }

    private func appIcon(pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    private struct SourceCard: View {
        let card: Card
        let image: CGImage?
        let selected: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

                HStack(spacing: 8) {
                    if let icon = card.icon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.title).font(.callout.weight(selected ? .semibold : .regular))
                            .lineLimit(1).truncationMode(.tail)
                        Text(card.subtitle).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
    }
}

/// Hosts the picker in its own window.
@MainActor
final class SourcePickerWindow {
    static let shared = SourcePickerWindow()
    private var window: NSWindow?
    private let model = SourcePickerModel()

    func show(onSelect: @escaping (CaptureSource) -> Void) {
        model.refresh()
        let view = SourcePickerView(model: model,
                                    onSelect: { [weak self] source in self?.close(); onSelect(source) },
                                    onCancel: { [weak self] in self?.close() })
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Choose what to record"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: view)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.orderOut(nil)
    }
}
