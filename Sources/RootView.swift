import SwiftUI
import Photos
import UserNotifications

struct RootView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        TabView {
            ReviewView().tabItem { Label("Review", systemImage: "photo.stack") }
            LogView().tabItem { Label("History", systemImage: "clock") }
        }
        .task {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            PhotoCleanupApp.schedule()
        }
    }
}

struct ReviewView: View {
    @EnvironmentObject var store: Store
    @State private var selected: Set<String> = []
    @State private var strong: Set<String> = []
    @State private var initialised = false
    private let cols = [GridItem(.adaptive(minimum: 100), spacing: 6)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.state.queue.isEmpty {
                    ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle",
                        description: Text(store.state.lastScan.map { "Last scan \($0.formatted(.relative(presentation: .named)))" } ?? "Tap Scan to start."))
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: cols, spacing: 6) {
                        ForEach(store.state.queue) { c in
                            Cell(c: c, on: selected.contains(c.id), protected: strong.contains(c.id))
                                .onTapGesture { toggle(c.id) }
                                .contextMenu {
                                    Button("Never delete photos like this", systemImage: "hand.raised") {
                                        selected.remove(c.id); strong.insert(c.id)
                                    }
                                }
                        }
                    }.padding(6)
                }
            }
            .navigationTitle("Review")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { _ = await store.scan(allowNetwork: true, full: true); seed() } } label: {
                        if store.scanning { HStack { ProgressView(); Text("\(store.progress)").font(.caption).monospacedDigit() } } else { Text("Scan all") }
                    }.disabled(store.scanning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !store.state.queue.isEmpty {
                    Button(role: .destructive) {
                        Task {
                            if await store.resolve(deleteIDs: selected, strongKeep: strong) {
                                selected = []; strong = []
                            }
                        }
                    } label: {
                        Text(selected.isEmpty ? "Keep all, teach the app" : "Delete \(selected.count) photos")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).padding()
                    .background(.bar)
                }
            }
            .onAppear { if !initialised { seed(); initialised = true } }
        }
    }

    private func toggle(_ id: String) {
        strong.remove(id)
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    /// Only high-confidence items start ticked; the rest need a tap.
    private func seed() {
        selected = Set(store.state.queue.filter { $0.score >= Scanner.preselectThreshold }.map(\.id))
    }
}

struct Cell: View {
    let c: Candidate; let on: Bool; let protected: Bool
    @State private var image: UIImage?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.gray.opacity(0.15)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            VStack {
                Spacer()
                HStack {
                    Text(c.reasons.map(\.label).joined(separator: " + "))
                        .font(.system(size: 9, weight: .semibold)).padding(3)
                        .background(.black.opacity(0.6)).foregroundStyle(.white).clipShape(Capsule())
                    Spacer()
                }.padding(3)
            }
            Image(systemName: protected ? "hand.raised.fill" : (on ? "checkmark.circle.fill" : "circle"))
                .foregroundStyle(protected ? .orange : (on ? .red : .white)).font(.title3).padding(4)
        }
        .frame(height: 110).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? .red : .clear, lineWidth: 2))
        .task {
            let a = PHAsset.fetchAssets(withLocalIdentifiers: [c.id], options: nil).firstObject
            if let a { image = await Scanner.thumbnail(a) }
        }
    }
}

struct LogView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationStack {
            List {
                if let st = store.state.lastStats {
                    Section("Last scan") {
                        LabeledContent("Photos in library", value: "\(st.libraryImages)")
                        LabeledContent("Examined", value: "\(st.examined)")
                        LabeledContent("Screenshots found", value: "\(st.screenshots)")
                        LabeledContent("WhatsApp found", value: "\(st.whatsapp)")
                        LabeledContent("Duplicates found", value: "\(st.duplicates)")
                        LabeledContent("Skipped: favorite or in album", value: "\(st.protectedFavOrAlbum)")
                        LabeledContent("Skipped: duplicates under 1 day old", value: "\(st.tooNew)")
                        LabeledContent("Skipped: people", value: "\(st.peopleSkipped)")
                        LabeledContent("Skipped: learned keep", value: "\(st.learnedProtected)")
                        LabeledContent("Could not load image", value: "\(st.thumbFail)")
                        LabeledContent("Scored too low", value: "\(st.belowThreshold)")
                        LabeledContent("Queued", value: "\(st.queued)")
                    }
                }
                Section("Learning") {
                    ForEach(Reason.allCases, id: \.self) { r in
                        let s = store.state.stats[r.rawValue] ?? ReasonStats()
                        LabeledContent(r.label, value: "\(s.deleted) deleted, \(s.kept) kept")
                    }
                    LabeledContent("Examples learned", value: "\(store.state.decisions.count)")
                }
                Section("Deleted (recoverable 30 days in Recently Deleted)") {
                    ForEach(store.state.log) { e in
                        LabeledContent(e.date.formatted(date: .abbreviated, time: .shortened), value: "\(e.deleted) photos")
                    }
                }
            }.navigationTitle("History")
        }
    }
}
