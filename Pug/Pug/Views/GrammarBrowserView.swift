// GrammarBrowserView.swift
// Grammar topic browser: filterable list with enrollment toggle.
// Housed in the Grammar tab alongside GrammarQuizView.
//
// Row tap: opens GrammarDetailSheet for full detail + enrollment toggle.
// Swipe actions:
//   Not yet learning: "Learn" (green) — enroll without opening the sheet
//   Learning: no swipe — use GrammarDetailSheet for deliberate changes
//
// Toolbar:
//   Leading: filter menu (Not yet learning / Learning / All)
//   Trailing: quiz button (when enrolled topics exist) + ··· menu (Settings, Re-download, last synced)

import SwiftUI
import GRDB

struct GrammarBrowserView: View {
    @State private var manifest: GrammarManifest
    let db: QuizDB
    @State var grammarSession: GrammarAppSession
    let client: AnthropicClient
    let toolHandler: ToolHandler?
    let jmdict: any DatabaseReader
    let onSync: () async -> Void

    @State private var enrollmentStatus: [String: Bool] = [:]   // topicId → enrolled
    @State private var searchText = ""
    @State private var filterEnrolled: EnrollmentFilter = .notEnrolled
    @State private var selectedTopic: IdentifiableTopic? = nil
    @State private var showQuiz = false
    @State private var isLoadingEnrollment = true
    @State private var showSettings = false
    @State private var lastSyncedAt: String?
    @State private var isSyncing = false
    @State private var dashboardRefreshID = 0

    @Environment(GrammarStore.self) private var grammarStore

    init(manifest: GrammarManifest, db: QuizDB, grammarSession: GrammarAppSession,
         client: AnthropicClient, toolHandler: ToolHandler? = nil,
         jmdict: any DatabaseReader, onSync: @escaping () async -> Void) {
        self._manifest = State(initialValue: manifest)
        self._lastSyncedAt = State(initialValue: manifest.generatedAt)
        self.db = db
        self._grammarSession = State(initialValue: grammarSession)
        self.client = client
        self.toolHandler = toolHandler
        self.jmdict = jmdict
        self.onSync = onSync
    }

    enum EnrollmentFilter: String, CaseIterable {
        case all = "All"
        case enrolled = "Learning"
        case notEnrolled = "Not yet learning"
    }

    // Topics after applying search + enrollment filter, sorted by level then title.
    // Equivalence group siblings are collapsed: only the canonical representative
    // (the topic whose prefixedId sorts first among all group members) is shown.
    private var filteredTopics: [GrammarTopic] {
        var seenGroupKeys = Set<String>()
        return manifest.topics.values
            .filter { topic in
                // Deduplicate equivalence groups: compute a stable canonical key
                // by taking the lexicographically smallest prefixed ID in the group.
                let groupMembers = ([topic.prefixedId] + (topic.equivalenceGroup ?? [])).sorted()
                let groupKey = groupMembers.first ?? topic.prefixedId
                guard seenGroupKeys.insert(groupKey).inserted else { return false }

                let enrolled = enrollmentStatus[topic.prefixedId] ?? false
                switch filterEnrolled {
                case .all: break
                case .enrolled: if !enrolled { return false }
                case .notEnrolled: if enrolled { return false }
                }
                if !searchText.isEmpty {
                    let q = searchText.lowercased()
                    let matchesTitle = topic.titleEn.lowercased().contains(q)
                    let matchesJp    = topic.titleJp?.lowercased().contains(q) ?? false
                    let matchesLevel = topic.level.lowercased().contains(q)
                    if !matchesTitle && !matchesJp && !matchesLevel { return false }
                }
                return true
            }
            .sorted {
                if $0.level != $1.level { return $0.level < $1.level }
                return $0.titleEn < $1.titleEn
            }
    }


    var body: some View {
        NavigationStack {
            Group {
                if isLoadingEnrollment {
                    ProgressView("Loading…")
                } else {
                    topicList
                }
            }
            .navigationTitle("Grammar")
            .searchable(text: $searchText, prompt: "Search topics")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { enrollmentFilterMenu }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 4) {
                        Button {
                            showQuiz = true
                        } label: {
                            Label("Quiz", systemImage: "brain.head.profile")
                        }
                        BrowserToolbarMenu(
                            showSettings: $showSettings,
                            db: db,
                            client: client,
                            lastSyncedAt: lastSyncedAt,
                            isDownloading: isSyncing,
                            onRedownload: {
                                Task {
                                    isSyncing = true
                                    await syncAll()
                                    isSyncing = false
                                }
                            }
                        )
                    }
                }
            }
            .sheet(item: $selectedTopic) { wrapper in
                GrammarDetailSheet(
                    topic: wrapper.topic,
                    manifest: manifest,
                    db: db,
                    client: client,
                    toolHandler: toolHandler,
                    isEnrolled: enrollmentStatus[wrapper.id] ?? false,
                    jmdict: jmdict
                ) { nowEnrolled in
                    let groupIds = wrapper.topic.equivalenceGroup ?? []
                    let allIds = [wrapper.id] + groupIds
                    for id in allIds { enrollmentStatus[id] = nowEnrolled }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(db: db) }
            .navigationDestination(isPresented: $showQuiz) {
                GrammarQuizView(session: grammarSession, manifest: manifest)
            }
            .onChange(of: showQuiz) { _, isShowing in
                if !isShowing { dashboardRefreshID += 1 }
            }
        }
        .task { await loadEnrollmentStatus() }
    }

    // MARK: - Topic list

    private var topicList: some View {
        List {
            if searchText.isEmpty {
                Section {
                    MotivationDashboardView(db: db, refreshID: dashboardRefreshID)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listSectionSeparator(.hidden)
            }
            ForEach(filteredTopics, id: \.prefixedId) { topic in
                Button {
                    selectedTopic = IdentifiableTopic(id: topic.prefixedId, topic: topic)
                } label: {
                    topicRow(topic)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    grammarSwipeButtons(for: topic)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if filteredTopics.isEmpty {
                ContentUnavailableView(
                    "No topics found",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search or filter.")
                )
            }
        }
    }

    private func topicRow(_ topic: GrammarTopic) -> some View {
        // equivalenceGroup IDs may reference topics not in this user's manifest
        // (e.g. a genki topic they haven't enrolled any stories for).
        // Split into resolved topics and bare IDs for the fallback.
        let siblingIds = topic.equivalenceGroup ?? []
        let siblingTopics = siblingIds.compactMap { manifest.topics[$0] }
        let allTopics = [topic] + siblingTopics

        // Slugs: use resolved id where available, else strip the "source:" prefix from the raw ID.
        let allSlugs: [String] = [topic.id] + siblingIds.map { id in
            manifest.topics[id]?.id ?? String(id.drop(while: { $0 != ":" }).dropFirst())
        }

        return HStack(spacing: 12) {
            Circle()
                .fill(enrollmentStatus[topic.prefixedId] == true ? Color.accentColor : Color(.systemGray4))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(allSlugs.joined(separator: " / "))
                    .font(.body)
                // Source badges: resolved topics get a badge; unresolved get one from the raw prefix
                HStack(spacing: 4) {
                    ForEach(allTopics, id: \.prefixedId) { t in
                        Text(t.source)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.12), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    ForEach(siblingIds.filter { manifest.topics[$0] == nil }, id: \.self) { rawId in
                        let src = String(rawId.prefix(while: { $0 != ":" }))
                        Text(src)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.12), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    // MARK: - Swipe actions

    @ViewBuilder
    private func grammarSwipeButtons(for topic: GrammarTopic) -> some View {
        if enrollmentStatus[topic.prefixedId] != true {
            Button {
                Task { await enrollTopic(topic) }
            } label: {
                Label("Learn", systemImage: "plus.circle.fill")
            }
            .tint(.green)
        }
    }

    private func enrollTopic(_ topic: GrammarTopic) async {
        let groupIds = topic.equivalenceGroup ?? []
        do {
            try await db.enrollGrammarTopic(topicId: topic.prefixedId, equivalenceGroupIds: groupIds)
            let allIds = [topic.prefixedId] + groupIds
            for id in allIds { enrollmentStatus[id] = true }
        } catch {
            print("[GrammarBrowserView] enroll failed for \(topic.prefixedId): \(error)")
        }
    }

    // MARK: - Toolbar items

    private var enrollmentFilterMenu: some View {
        Menu {
            Button {
                filterEnrolled = .notEnrolled
            } label: {
                Label(filterEnrolled == .notEnrolled ? "Not yet learning ✓" : "Not yet learning",
                      systemImage: "tray.and.arrow.down")
            }
            Button {
                filterEnrolled = .enrolled
            } label: {
                Label(filterEnrolled == .enrolled ? "Learning ✓" : "Learning",
                      systemImage: "checkmark.circle.fill")
            }
            Divider()
            Button {
                filterEnrolled = .all
            } label: {
                Label(filterEnrolled == .all ? "All ✓" : "All",
                      systemImage: "list.bullet")
            }
        } label: {
            HStack(spacing: 3) {
                Text(enrollmentFilterLabel).font(.subheadline)
                Image(systemName: "chevron.down").imageScale(.small)
            }
        }
    }

    private var enrollmentFilterLabel: String {
        switch filterEnrolled {
        case .all:         return "All"
        case .enrolled:    return "Learning"
        case .notEnrolled: return "Not yet learning"
        }
    }

    // MARK: - Data

    private func loadEnrollmentStatus() async {
        do {
            let records = try await db.enrolledGrammarRecords()
            var status: [String: Bool] = [:]
            for r in records { status[r.wordId] = true }
            enrollmentStatus = status
        } catch {
            print("[GrammarBrowserView] failed to load enrollment: \(error)")
        }
        isLoadingEnrollment = false
    }

    private func syncAll() async {
        await onSync()
        // onSync updates grammarStore.manifest via AppRootView; pull the new value into local state.
        if let updated = grammarStore.manifest {
            manifest = updated
            lastSyncedAt = ISO8601DateFormatter().string(from: Date())
        }
    }
}

// MARK: - Wrapper so sheet(item:) uses the globally unique prefixed ID

private struct IdentifiableTopic: Identifiable {
    let id: String          // prefixedId — globally unique
    let topic: GrammarTopic
}
