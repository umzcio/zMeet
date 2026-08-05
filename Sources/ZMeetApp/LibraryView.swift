import SwiftUI
import AppKit
import AVFoundation
import ZMeetCore

// MARK: - Library window (conversation-rail layout)

struct LibraryView: View {
    @ObservedObject var state: AppState
    // Held (not observed) by the root — the 4Hz playback ticker would otherwise
    // re-render the whole window. Only PlayerBar observes it.
    @State private var audio = AudioPlayerModel()

    @State private var query = ""
    @State private var tab: Tab = .notes
    @State private var noteBlocks: [NoteBlock] = []
    @State private var transcriptText: String?
    // Distinguishes "not loaded yet" (nil text, spinner) from "loaded and
    // genuinely empty" (nil text, "no transcript" message) — both leave
    // transcriptText nil, so this flag disambiguates them.
    @State private var transcriptLoaded = false
    @State private var renameText = ""
    @State private var searchHits: [SearchHit] = []
    @State private var searchTask: Task<Void, Never>?

    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    enum Tab { case notes, transcript }

    // Mint-terminal palette (matches the approved mock). Canonical colors now
    // live in ZMeetPalette; see ZMeetPalette.swift.

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                railColumn
                Rectangle().fill(ZMeetPalette.hairline).frame(width: 1)
                mainColumn
            }

            if state.libraryDialog == .rename, let session = selected {
                renameDialog(session)
            }
            if state.libraryDialog == .delete, let session = selected {
                deleteDialog(session)
            }
            if state.libraryDialog == .deleteAudio, let session = selected {
                deleteAudioDialog(session)
            }
        }
        .animation(state.libraryDialog == nil ? DialogScaffold<EmptyView>.disappear : DialogScaffold<EmptyView>.appear,
                   value: state.libraryDialog)
        // Read rail-row anchors from the whole tree (the rows live in railColumn)
        // and float the right-click menu under the clicked row.
        .overlayPreferenceValue(RailRowAnchorKey.self) { anchors in
            contextMenu(anchors: anchors)
        }
        .frame(width: 1000, height: 680)
        .background(ZMeetPalette.bg)
        .preferredColorScheme(.dark)
        .tint(ZMeetPalette.mint)
        .onReceive(ticker) { _ in if audio.isPlaying { audio.tick() } }
        .task(id: reloadKey) { await loadSelected() }
        .task(id: transcriptLoadKey) { await loadTranscriptIfNeeded() }
        .onChange(of: selected?.id) { state.showLibraryActions = false; state.libraryContextSession = nil }
        .onChange(of: query) { runSearch() }
    }

    // MARK: In-app dialogs (custom, to match the app rather than system alerts)

    private func renameDialog(_ session: MeetingSession) -> some View {
        DialogScaffold(onDismiss: { state.libraryDialog = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename meeting")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ZMeetPalette.light)

                DialogTextField(text: $renameText, placeholder: "Meeting title") {
                    commitRename(session)
                }

                HStack(spacing: 10) {
                    Spacer()
                    DialogButton(title: "Cancel", kind: .secondary) { state.libraryDialog = nil }
                    DialogButton(title: "Rename", kind: .primary) { commitRename(session) }
                }
            }
        }
    }

    private func deleteDialog(_ session: MeetingSession) -> some View {
        DialogScaffold(onDismiss: { state.libraryDialog = nil }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Delete this meeting?")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ZMeetPalette.light)
                Text("This removes the recording, transcript, and notes for “\(session.title)”. This can't be undone.")
                    .font(.system(size: 13))
                    .foregroundStyle(ZMeetPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer()
                    DialogButton(title: "Cancel", kind: .secondary) { state.libraryDialog = nil }
                    DialogButton(title: "Delete", kind: .destructive) {
                        let wasSelected = session.id
                        state.deleteMeeting(id: session.id)
                        if state.librarySelectedID == wasSelected { state.librarySelectedID = nil }
                        state.libraryDialog = nil
                    }
                }
            }
        }
    }

    private func deleteAudioDialog(_ session: MeetingSession) -> some View {
        DialogScaffold(onDismiss: { state.libraryDialog = nil }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Delete audio for this meeting?")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ZMeetPalette.light)
                Text("Removes the recording for \u{201C}\(session.title)\u{201D} to save space. The transcript and notes are kept. This can't be undone.")
                    .font(.system(size: 13))
                    .foregroundStyle(ZMeetPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer()
                    DialogButton(title: "Cancel", kind: .secondary) { state.libraryDialog = nil }
                        .keyboardShortcut(.cancelAction)
                    DialogButton(title: "Delete Audio", kind: .destructive) {
                        state.deleteAudio(id: session.id)
                        state.libraryDialog = nil
                    }
                }
            }
        }
    }

    private func commitRename(_ session: MeetingSession) {
        state.renameMeeting(id: session.id, to: renameText)
        state.libraryDialog = nil
    }

    // MARK: Selection

    /// The rail always shows every meeting; search results live in the main pane.
    private var meetings: [MeetingSession] { state.allSessions }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var selected: MeetingSession? {
        let id = state.librarySelectedID
        return state.allSessions.first { $0.id == id } ?? state.allSessions.first
    }

    /// Reload the reader whenever the selected meeting — or its processing
    /// status — changes (e.g. after a re-process completes). The trailing flag
    /// flips when this meeting starts/finishes processing, so the reader
    /// refreshes even when a re-process leaves the status `.processed` unchanged.
    private var reloadKey: String {
        let processing = state.processingSessionID == selected?.id
        return "\(selected?.id ?? "none")-\(selected?.status.rawValue ?? "")-\(processing)"
    }

    /// Drives on-demand transcript loading: re-evaluates whenever the selected
    /// meeting or the active tab changes.
    private var transcriptLoadKey: String {
        "\(selected?.id ?? "none")-\(tab)"
    }

    /// True while the selected meeting is being (re)processed.
    private var selectedIsProcessing: Bool {
        selected != nil && state.processingSessionID == selected?.id
    }

    // MARK: Left rail

    private var railColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(" z").font(.custom("Dancing Script", size: 30)).foregroundStyle(ZMeetPalette.mint)
                    Text("Meet").font(.system(size: 22, weight: .bold))
                }
                .padding(.leading, 4)
                .padding(.top, 30)
                .padding(.bottom, 14)

                searchField
            }
            .padding(.horizontal, 16)

            meetingList

            railFooter
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(ZMeetPalette.rail)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(ZMeetPalette.muted)
            TextField("Search meetings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(ZMeetPalette.light)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(ZMeetPalette.card, in: RoundedRectangle(cornerRadius: 11))
        .padding(.bottom, 6)
    }

    private var meetingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                if meetings.isEmpty {
                    Text(query.isEmpty ? "No meetings yet" : "No matches")
                        .font(.system(size: 13)).foregroundStyle(ZMeetPalette.muted)
                        .padding(.horizontal, 18).padding(.top, 16)
                } else {
                    ForEach(MeetingGrouping.groups(meetings), id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(ZMeetPalette.faint)
                            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
                        ForEach(group.sessions, id: \.id) { session in
                            railRow(session)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity)
    }

    private func railRow(_ session: MeetingSession) -> some View {
        let active = session.id == selected?.id
        return Button {
            state.showLibraryActions = false
            state.librarySelectedID = session.id
        } label: {
            HStack(spacing: 11) {
                railGlyph(session).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(active ? ZMeetPalette.mint : ZMeetPalette.light)
                        .lineLimit(1)
                    Text(railSubtitle(session))
                        .font(.system(size: 11.5))
                        .foregroundStyle(ZMeetPalette.muted)
                }
                Spacer(minLength: 0)
                railStatus(session)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(active ? ZMeetPalette.mint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(RightClickCatcher { showContextMenu(session) })
        .anchorPreference(key: RailRowAnchorKey.self, value: .bounds) { [session.id: $0] }
    }

    private func showContextMenu(_ session: MeetingSession) {
        state.showLibraryActions = false
        state.librarySelectedID = session.id
        state.libraryContextSession = session
    }

    /// Close whichever actions menu is open (the ⋯ overlay and/or the rail
    /// right-click context menu).
    private func closeMenus() {
        state.showLibraryActions = false
        state.libraryContextSession = nil
    }

    /// The rail right-click menu: the same actions dropdown, positioned at the
    /// right-clicked row via its anchor, with a tap-catcher to dismiss.
    @ViewBuilder
    private func contextMenu(anchors: [String: Anchor<CGRect>]) -> some View {
        if let session = state.libraryContextSession, let anchor = anchors[session.id] {
            GeometryReader { proxy in
                let rect = proxy[anchor]
                // Estimate the menu height to decide whether it fits below the row;
                // if not, open it upward so it never clips at the window bottom.
                let hasAudio = session.status == .processed
                    && FileManager.default.fileExists(atPath: session.audioPath)
                let rowCount = 4 + (hasAudio ? 1 : 0)
                let menuHeight = CGFloat(rowCount) * 34 + 19
                let belowY = rect.maxY + 2
                let y = (belowY + menuHeight > 680 - 8)
                    ? max(8, rect.minY - menuHeight - 2)
                    : belowY
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { state.libraryContextSession = nil }
                    actionsDropdown(session)
                        .offset(x: min(rect.minX, 1000 - 196 - 8), y: y)
                }
            }
        }
    }

    /// The leading glyph for a rail row: the real Zoom/Teams app icon when known,
    /// otherwise a mint dot for in-person / manual meetings.
    @ViewBuilder
    private func railGlyph(_ session: MeetingSession) -> some View {
        switch MeetingSource.of(session) {
        case .zoom, .teams:
            Image(nsImage: SourceAppIcons.icon(for: session.sourceApp, title: session.title))
                .resizable()
                .frame(width: 17, height: 17)
        case .generic:
            Circle().fill(ZMeetPalette.mint).frame(width: 9, height: 9)
        }
    }

    @ViewBuilder
    private func railStatus(_ session: MeetingSession) -> some View {
        if state.processingSessionID == session.id {
            // Being (re)processed right now — show a spinner regardless of the
            // persisted status (a re-processed meeting stays `.processed`).
            ProgressView().controlSize(.small).scaleEffect(0.7)
        } else {
            switch session.status {
            case .recording:
                ProgressView().controlSize(.small).scaleEffect(0.7)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            case .recorded:
                Image(systemName: "circle.dashed")
                    .font(.system(size: 11)).foregroundStyle(ZMeetPalette.faint)
            case .processed:
                EmptyView()
            }
        }
    }

    private var railFooter: some View {
        HStack(spacing: 4) {
            miniButton("gearshape", "Settings") { state.openSettings() }
            miniButton("arrow.triangle.2.circlepath", "Check for Updates…") { state.updater.checkForUpdates() }
            miniButton("folder", "Open notes folder") { state.openOutputFolder() }
            Spacer()
            miniButton("power", "Quit zMeet") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(Rectangle().fill(ZMeetPalette.hairline).frame(height: 1), alignment: .top)
    }

    private func miniButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(ZMeetPalette.faint)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Main column

    @ViewBuilder
    private var mainColumn: some View {
        if isSearching {
            searchResultsPanel
        } else if let session = selected {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    meetingHeader(session)
                    tabBar
                    reader(session)
                    if FileManager.default.fileExists(atPath: session.audioPath) {
                        PlayerBar(audio: audio)
                    } else if session.status == .processed {
                        audioRemovedCaption
                    }
                }

                if state.showLibraryActions {
                    // Tap-catcher to dismiss the in-app dropdown.
                    Color.black.opacity(0.001)
                        .onTapGesture { state.showLibraryActions = false }
                    actionsDropdown(session)
                        .padding(.top, 60)
                        .padding(.trailing, 32)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ZMeetPalette.bg)
        } else {
            emptyState
        }
    }

    private func meetingHeader(_ session: MeetingSession) -> some View {
        HStack(alignment: .center, spacing: 15) {
            Image(nsImage: SourceAppIcons.icon(for: session.sourceApp, title: session.title))
                .resizable()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(ZMeetPalette.light)
                    .lineLimit(1)
                Text(metaLine(session))
                    .font(.system(size: 13))
                    .foregroundStyle(ZMeetPalette.muted)
            }
            Spacer()
            if selectedIsProcessing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text("Processing…").font(.system(size: 12)).foregroundStyle(ZMeetPalette.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ZMeetPalette.card, in: Capsule())
            }
            headerActions(session)
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    private func headerActions(_ session: MeetingSession) -> some View {
        HStack(spacing: 8) {
            actionButton("arrow.up.forward.app", "Reveal in Finder") { state.revealNote(session) }
            actionButton("ellipsis", "Actions") {
                state.showLibraryActions.toggle()
            }
        }
    }

    private func actionButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(ZMeetPalette.muted)
                .frame(width: 38, height: 38)
                .background(ZMeetPalette.card, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// A custom, in-app styled dropdown (replaces the system context menu) for the
    /// per-meeting actions.
    private func actionsDropdown(_ session: MeetingSession) -> some View {
        VStack(spacing: 0) {
            DropdownRow(title: "Rename…") {
                renameText = session.title; closeMenus(); state.libraryDialog = .rename
            }
            // A meeting that's actively recording can't be (re)processed yet — the
            // Core guard already refuses it, but the UI shouldn't offer it either.
            if session.status != .recording {
                DropdownRow(title: session.status == .processed ? "Re-process" : "Process Notes") {
                    state.process(id: session.id); closeMenus()
                }
            }
            DropdownRow(title: "Reveal in Finder") {
                state.revealNote(session); closeMenus()
            }
            if session.status == .processed,
               FileManager.default.fileExists(atPath: session.audioPath) {
                DropdownRow(title: "Delete audio…") {
                    closeMenus(); state.libraryDialog = .deleteAudio
                }
            }
            Rectangle().fill(ZMeetPalette.hairline).frame(height: 1).padding(.vertical, 4)
            DropdownRow(title: "Delete…", destructive: true) {
                closeMenus(); state.libraryDialog = .delete
            }
        }
        .padding(.vertical, 5)
        .frame(width: 196)
        .background(Color(red: 0.118, green: 0.137, blue: 0.129), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ZMeetPalette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
    }

    private var tabBar: some View {
        HStack(spacing: 26) {
            tabButton("Notes", .notes)
            tabButton("Transcript", .transcript)
            Spacer()
        }
        .padding(.horizontal, 34)
        .overlay(Rectangle().fill(ZMeetPalette.hairline).frame(height: 1), alignment: .bottom)
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        let active = tab == value
        return Button { tab = value } label: {
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(active ? ZMeetPalette.light : ZMeetPalette.muted)
                Rectangle()
                    .fill(active ? ZMeetPalette.mint : .clear)
                    .frame(height: 2)
            }
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder
    private func reader(_ session: MeetingSession) -> some View {
        ScrollView {
            Group {
                switch tab {
                case .notes:    notesBody(session)
                case .transcript: transcriptBody(session)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func notesBody(_ session: MeetingSession) -> some View {
        if session.status != .processed {
            unprocessedState(session)
        } else if noteBlocks.isEmpty {
            Text("No notes were generated for this meeting.")
                .font(.system(size: 15)).foregroundStyle(ZMeetPalette.muted)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(noteBlocks.enumerated()), id: \.offset) { _, block in
                    block.view
                }
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func transcriptBody(_ session: MeetingSession) -> some View {
        if let text = transcriptText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Chunked into paragraphs (rather than one monolithic Text) so a long
            // transcript lays out incrementally instead of re-flowing 50-150KB of
            // text on every invalidation. Trade-off: text selection no longer
            // spans across paragraph breaks.
            let paragraphs = text.components(separatedBy: "\n\n").filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: 14.5))
                        .foregroundStyle(ZMeetPalette.body)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                }
            }
        } else if session.status == .processed && !transcriptLoaded {
            ProgressView().controlSize(.small)
        } else {
            Text(session.status == .processed
                 ? "No transcript was saved for this meeting."
                 : "The transcript appears after this meeting is processed.")
                .font(.system(size: 15)).foregroundStyle(ZMeetPalette.muted)
        }
    }

    @ViewBuilder
    private func unprocessedState(_ session: MeetingSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if session.status == .failed {
                Label("Processing failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
                if let msg = session.errorMessage {
                    Text(msg).font(.system(size: 13)).foregroundStyle(ZMeetPalette.muted)
                }
            } else {
                Text("This meeting hasn't been processed yet.")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(ZMeetPalette.light)
                Text("Transcribe and summarize it on-device to generate notes.")
                    .font(.system(size: 14)).foregroundStyle(ZMeetPalette.muted)
            }
            Button {
                state.process(id: session.id)
            } label: {
                Label(state.processingSessionID != nil ? "Processing…" : "Process Notes", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent).tint(ZMeetPalette.mint)
            .disabled(state.processingSessionID != nil || session.status == .recording)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(ZMeetPalette.faint)
            Text("No meetings yet")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(ZMeetPalette.light)
            Text("Record a meeting from the menu bar and it will appear here.")
                .font(.system(size: 14)).foregroundStyle(ZMeetPalette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZMeetPalette.bg)
    }

    // MARK: Audio player

    private var audioRemovedCaption: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash").font(.system(size: 13)).foregroundStyle(ZMeetPalette.faint)
            Text("Audio removed to save space").font(.system(size: 12.5)).foregroundStyle(ZMeetPalette.muted)
            Spacer()
        }
        .padding(.horizontal, 32).padding(.vertical, 16)
        .overlay(Rectangle().fill(ZMeetPalette.hairline).frame(height: 1), alignment: .top)
    }

    // MARK: Loading + formatting

    // MARK: Search results panel

    private var searchResultsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Results for \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}")
                .font(.system(size: 13)).foregroundStyle(ZMeetPalette.muted)
                .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 14)

            if searchHits.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(ZMeetPalette.faint)
                    Text("No results").font(.system(size: 16, weight: .semibold)).foregroundStyle(ZMeetPalette.light)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(searchHits, id: \.sessionID) { hit in
                            if let session = state.allSessions.first(where: { $0.id == hit.sessionID }) {
                                searchResultRow(session, hit: hit)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZMeetPalette.bg)
    }

    private func searchResultRow(_ session: MeetingSession, hit: SearchHit) -> some View {
        Button {
            state.librarySelectedID = session.id
            query = ""
            searchHits = []
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: SourceAppIcons.icon(for: session.sourceApp, title: session.title))
                    .resizable().frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 14.5, weight: .semibold)).foregroundStyle(ZMeetPalette.light)
                        .lineLimit(1)
                    Text(metaLine(session))
                        .font(.system(size: 11.5)).foregroundStyle(ZMeetPalette.muted)
                    highlightedSnippet(hit.snippet)
                        .font(.system(size: 13)).foregroundStyle(ZMeetPalette.body)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(ZMeetPalette.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Convert a snippet with U+0002/U+0003 markers into highlighted Text.
    private func highlightedSnippet(_ snippet: String) -> Text {
        var result = Text("")
        let chunks = snippet.components(separatedBy: SearchStore.highlightStart)
        for (i, chunk) in chunks.enumerated() {
            if i == 0 {
                result = result + Text(chunk)
                continue
            }
            let parts = chunk.components(separatedBy: SearchStore.highlightEnd)
            if let match = parts.first {
                result = result + Text(match).foregroundColor(ZMeetPalette.mint).bold()
            }
            if parts.count > 1 {
                result = result + Text(parts.dropFirst().joined(separator: SearchStore.highlightEnd))
            }
        }
        return result
    }

    private func runSearch() {
        searchTask?.cancel()
        let raw = query.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { searchHits = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let hits = await state.searchMeetings(raw)
            if Task.isCancelled { return }
            searchHits = hits
        }
    }

    @MainActor
    private func loadSelected() async {
        tab = .notes
        audio.stop()
        transcriptText = nil
        transcriptLoaded = false
        guard let session = selected else {
            noteBlocks = []; return
        }
        noteBlocks = NoteBlock.parse(state.readNote(session) ?? "")
        let url = URL(fileURLWithPath: session.audioPath)
        if FileManager.default.fileExists(atPath: url.path) {
            audio.load(url)
        }
    }

    /// The transcript is large (up to ~150KB) and only needed when the
    /// Transcript tab is actually visible, so it's loaded on demand — off the
    /// main actor, since `readTranscript` is a pure file read keyed on the
    /// session's `transcriptPath`.
    @MainActor
    private func loadTranscriptIfNeeded() async {
        guard tab == .transcript, !transcriptLoaded, let session = selected else { return }
        let path = session.transcriptPath
        let text: String? = if let path {
            await Task.detached(priority: .userInitiated) {
                try? String(contentsOfFile: path, encoding: .utf8)
            }.value
        } else {
            nil
        }
        // The selection may have changed while the read was in flight.
        guard selected?.id == session.id, tab == .transcript else { return }
        transcriptText = text
        transcriptLoaded = true
    }

    private func railSubtitle(_ session: MeetingSession) -> String {
        let cal = Calendar.current
        let label: String
        if cal.isDateInToday(session.startedAt) {
            label = Self.timeFormatter.string(from: session.startedAt)
        } else if cal.isDateInYesterday(session.startedAt) {
            label = "Yesterday"
        } else {
            label = Self.weekdayFormatter.string(from: session.startedAt)
        }
        if let dur = durationShort(session) { return "\(label) · \(dur)" }
        return label
    }

    private func metaLine(_ session: MeetingSession) -> String {
        var parts = [Self.dateFormatter.string(from: session.startedAt),
                     Self.timeFormatter.string(from: session.startedAt)]
        if let dur = durationShort(session) { parts.append(dur) }
        parts.append(MeetingSource.of(session).label)
        if let m = modeLabel(session.mode) { parts.append(m) }
        return parts.joined(separator: " · ")
    }

    private func modeLabel(_ mode: RecordingMode?) -> String? {
        switch mode {
        case .remote: "Remote"
        case .hybrid: "Hybrid"
        case .inPerson: "In-person"
        case nil: nil
        }
    }

    private func durationShort(_ session: MeetingSession) -> String? {
        guard let end = session.endedAt else { return nil }
        let total = Int(end.timeIntervalSince(session.startedAt))
        guard total > 0 else { return nil }
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return String(format: "%dh %02d min", h, m) }
        return "\(max(1, m)) min"
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
}

// MARK: - Player bar (the only view that observes AudioPlayerModel)

/// Scoped to just the transport controls so the 4Hz playback ticker
/// invalidates this small subtree instead of the whole library window.
private struct PlayerBar: View {
    @ObservedObject var audio: AudioPlayerModel

    var body: some View {
        HStack(spacing: 18) {
            Button { audio.toggle() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(red: 0.024, green: 0.157, blue: 0.102))
                    .frame(width: 44, height: 44)
                    .background(ZMeetPalette.mint, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(audio.duration <= 0)

            Text(timeString(audio.currentTime))
                .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(ZMeetPalette.muted)

            scrubber

            Text(timeString(audio.duration))
                .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(ZMeetPalette.muted)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .overlay(Rectangle().fill(ZMeetPalette.hairline).frame(height: 1), alignment: .top)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let fraction = audio.duration > 0 ? audio.currentTime / audio.duration : 0
            ZStack(alignment: .leading) {
                Capsule().fill(ZMeetPalette.card)
                Capsule().fill(ZMeetPalette.mint).frame(width: max(0, geo.size.width * fraction))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    let f = min(max(0, value.location.x / geo.size.width), 1)
                    audio.seek(toFraction: f)
                }
            )
        }
        .frame(height: 5)
        .frame(maxWidth: .infinity)
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Rail row anchor preference key

/// Carries each rail row's bounds up to the body so the right-click context menu
/// can be positioned under the clicked row.
private struct RailRowAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - In-app dropdown row

private struct DropdownRow: View {
    let title: String
    var destructive = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(destructive ? Color(red: 0.95, green: 0.42, blue: 0.38) : ZMeetPalette.light)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(hover ? ZMeetPalette.hover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .padding(.horizontal, 5)
    }
}

// MARK: - Source classification (dot color + label)

enum MeetingSource {
    case zoom, teams, generic

    static func of(_ session: MeetingSession) -> MeetingSource {
        let hay = "\(session.sourceApp ?? "") \(session.title)".lowercased()
        if hay.contains("zoom") { return .zoom }
        if hay.contains("teams") { return .teams }
        return .generic
    }

    var dotColor: Color {
        switch self {
        case .zoom:    return Color(red: 0.176, green: 0.549, blue: 1.0)
        case .teams:   return Color(red: 0.314, green: 0.349, blue: 0.788)
        case .generic: return ZMeetPalette.mint
        }
    }

    var label: String {
        switch self {
        case .zoom:    return "Zoom"
        case .teams:   return "Microsoft Teams"
        case .generic: return "zMeet"
        }
    }
}

// MARK: - Date grouping

enum MeetingGrouping {
    struct Group { let title: String; let sessions: [MeetingSession] }

    static func groups(_ sessions: [MeetingSession]) -> [Group] {
        let cal = Calendar.current
        var today: [MeetingSession] = []
        var yesterday: [MeetingSession] = []
        var week: [MeetingSession] = []
        var earlier: [MeetingSession] = []

        for s in sessions {
            if cal.isDateInToday(s.startedAt) {
                today.append(s)
            } else if cal.isDateInYesterday(s.startedAt) {
                yesterday.append(s)
            } else if let days = cal.dateComponents([.day], from: s.startedAt, to: Date()).day, days < 7 {
                week.append(s)
            } else {
                earlier.append(s)
            }
        }

        return [
            ("Today", today), ("Yesterday", yesterday),
            ("Earlier this week", week), ("Earlier", earlier)
        ].compactMap { $0.1.isEmpty ? nil : Group(title: $0.0, sessions: $0.1) }
    }
}

// MARK: - Lightweight Markdown rendering for notes.md

enum NoteBlock {
    case h2(String)
    case h3(String)
    case bullet(String)
    case paragraph(String)

    /// Parses a notes.md document into renderable blocks. Strips YAML frontmatter,
    /// the leading `# Title` (shown in the header), and the trailing transcript
    /// link section (the Transcript tab covers it).
    static func parse(_ raw: String) -> [NoteBlock] {
        var lines = raw.components(separatedBy: "\n")

        // Drop YAML frontmatter.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                lines = Array(lines[(end + 1)...])
            }
        }

        var blocks: [NoteBlock] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("# ") { continue } // title shown in header
            if t.lowercased() == "## transcript" { break } // tab covers the transcript
            if t.hasPrefix("### ") {
                blocks.append(.h3(String(t.dropFirst(4))))
            } else if t.hasPrefix("## ") {
                blocks.append(.h2(String(t.dropFirst(3))))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                let item = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { blocks.append(.bullet(item)) }
            } else {
                blocks.append(.paragraph(t))
            }
        }
        return blocks
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .h2(let s):
            Text(s.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(ZMeetPalette.mint)
                .padding(.top, 22).padding(.bottom, 8)
        case .h3(let s):
            Text(s)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ZMeetPalette.light)
                .padding(.top, 14).padding(.bottom, 4)
        case .bullet(let s):
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(ZMeetPalette.muted).frame(width: 5, height: 5).padding(.top, 9)
                NoteBlock.inline(s)
                    .font(.system(size: 15)).foregroundStyle(ZMeetPalette.body)
                    .lineSpacing(5)
            }
            .padding(.vertical, 3)
        case .paragraph(let s):
            NoteBlock.inline(s)
                .font(.system(size: 15)).foregroundStyle(ZMeetPalette.body)
                .lineSpacing(5)
                .padding(.vertical, 5)
        }
    }

    /// Renders inline Markdown (**bold**, *italic*, links) within a line.
    static func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(s)
    }
}

// MARK: - Audio playback

@MainActor
final class AudioPlayerModel: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var player: AVAudioPlayer?

    func load(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause(); isPlaying = false
        } else {
            player.play(); isPlaying = true
        }
    }

    func seek(toFraction f: Double) {
        guard let player, duration > 0 else { return }
        player.currentTime = f * duration
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    /// Called on a timer from the view to advance the scrubber.
    func tick() {
        guard let player else { return }
        if currentTime != player.currentTime {
            currentTime = player.currentTime
        }
        if isPlaying && !player.isPlaying {
            // Reached the end.
            isPlaying = false
            currentTime = 0
            player.currentTime = 0
        }
    }
}
