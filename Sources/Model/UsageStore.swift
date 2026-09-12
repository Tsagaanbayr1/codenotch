import AppKit
import Combine
import os

/// Fetches every provider on a timer and keeps the last good answer around, so
/// a dropped network shows yesterday's number dimmed rather than a blank ring.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    /// Providers with a fetch in flight, so the cell can show it happening.
    @Published private(set) var refreshing: Set<String> = []
    private let providers: [UsageProvider]
    /// Providers the user has switched off. They are not fetched at all — the
    /// tool behind them is never run and its files never opened, which is the
    /// whole point of switching one off. Filtering the results afterwards would
    /// still have done the work.
    @Published var disconnected: Set<String> = [] {
        didSet {
            guard disconnected != oldValue else { return }
            snapshots.removeAll { disconnected.contains($0.id) }
            // The remembered reading has to go as well. Dropping it from
            // `snapshots` alone left it in `lastGood`, which is written to the
            // archive wholesale on every fetch — so a switched-off provider was
            // remembered forever and rebuilt from the archive at the next
            // launch, ring and all.
            for id in disconnected { lastGood.removeValue(forKey: id) }
            archive.save(lastGood)
            refreshNow()
        }
    }

    /// Whether any provider is actively being used right now. Your usage cannot
    /// move while nothing is running, so polling hard through a quiet afternoon
    /// spends rate-limit budget to re-read a number that has not changed.
    var isBusy: () -> Bool = { false }

    private let refreshInterval: TimeInterval
    /// How long a snapshot stays believable after its last successful fetch.
    ///
    /// Comfortably above `idleRefreshInterval`, on purpose. With the two equal,
    /// a ring dimmed the instant the *first* idle refresh attempt failed —
    /// which reads as "nothing is being read any more" when what actually
    /// happened is one attempt, five minutes ago, out of what will keep being
    /// tried every five minutes after. The margin buys room for a couple of
    /// those attempts to have genuinely failed before the ring says so; it
    /// must never fire merely because the idle schedule hasn't come round yet.
    private let staleAfter: TimeInterval
    /// How often to look while something is running.
    ///
    /// Five minutes, not the every-tick poll this used to do. A reading is no
    /// longer a request — `ClaudeCLIProvider` spawns Claude Code and
    /// `CodexLocalProvider` spawns Codex, seconds of real CPU each — and a
    /// number that moves by a percentage point an hour does not repay doing
    /// that every minute on battery. Nothing is lost at the moment it matters:
    /// opening the notch and clicking a ring both refresh immediately, and
    /// `refresh(providerID:)` deliberately bypasses this schedule.
    private let busyRefreshInterval: TimeInterval
    /// How often to look when nothing is running.
    ///
    /// Longer again, because usage cannot move while nothing is running: the
    /// only thing an idle poll can discover is a window having rolled over.
    private let idleRefreshInterval: TimeInterval
    private var lastAttempt: Date?

    private let archive: UsageArchive
    private var lastGood: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] = [:]
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    /// Set synchronously before the task exists, so "is one already running"
    /// never depends on when the task body happens to start.
    private var isRefreshing = false
    private var wakeObserver: NSObjectProtocol?

    init(
        providers: [UsageProvider],
        refreshInterval: TimeInterval = 60,
        busyRefreshInterval: TimeInterval = 5 * 60,
        idleRefreshInterval: TimeInterval = 15 * 60,
        staleAfter: TimeInterval = 45 * 60,
        archive: UsageArchive = UsageArchive(),
        disconnected: Set<String> = []
    ) {
        self.providers = providers
        self.refreshInterval = refreshInterval
        self.busyRefreshInterval = busyRefreshInterval
        self.idleRefreshInterval = idleRefreshInterval
        self.staleAfter = staleAfter
        self.archive = archive

        // Open on what we knew last time rather than on an empty ring; the
        // first fetch will either confirm it or replace it.
        // Set through the wrapper's storage, not `self.disconnected = …`.
        // `disconnected` is `@Published`, so a plain assignment here runs its
        // `didSet` — which saves `lastGood` to the archive. At this point
        // `lastGood` is still empty, so it wrote an empty archive and destroyed
        // every remembered reading on any launch with a provider switched off.
        _disconnected = Published(initialValue: disconnected)
        lastGood = archive.load()
        // Pruned here as well as in `didSet`, because `didSet` cannot be relied
        // on to run: it guards against a no-op change, and the value the
        // preference binding delivers a moment later is usually identical to
        // the one passed in here. A provider switched off in a previous session
        // would then keep its archived reading indefinitely.
        if lastGood.keys.contains(where: disconnected.contains) {
            for id in disconnected { lastGood.removeValue(forKey: id) }
            archive.save(lastGood)
        }
        // Filtered here, not only in `didSet`. The store is built before the
        // preference reaches it, so an unfiltered first pass draws every
        // switched-off provider for as long as it takes the binding to arrive.
        snapshots = providers.filter { !disconnected.contains($0.id) }.map { provider in
            guard let remembered = lastGood[provider.id] else { return Self.placeholder(provider) }
            var snapshot = remembered.snapshot
            snapshot.status = .stale(since: remembered.fetchedAt)
            return snapshot
        }
    }

    /// Enough to list the providers in settings without exposing them.
    var providerSummaries: [ProviderSummary] {
        providers.map { provider in
            ProviderSummary(id: provider.id, name: provider.displayName,
                            glyph: provider.glyph, account: provider.account(),
                            signIn: provider.signInRoute)
        }
    }

    func start() {
        refreshNow()

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Waking up is the one moment the numbers are guaranteed to be wrong.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        isRefreshing = false
        // Block-based observers are not removed by `removeObserver(self)`.
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Decides whether this tick is worth a request at all.
    private func tick() {
        let waited = lastAttempt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard Self.shouldRefresh(
            isBusy: isBusy(),
            sinceLastAttempt: waited,
            busyInterval: busyRefreshInterval,
            idleInterval: idleRefreshInterval
        ) else { return }
        refreshNow()
    }

    /// Wait out the busy interval while something is running, the longer idle
    /// one otherwise. Pure, so the schedule can be tested without a clock.
    ///
    /// Being busy no longer means polling on every tick. It used to, back when
    /// a reading was one HTTPS request; now each one spawns the vendor's CLI,
    /// and a session left running overnight would have spent the night
    /// launching Claude Code once a minute to be told the same number.
    static func shouldRefresh(
        isBusy: Bool,
        sinceLastAttempt: TimeInterval,
        busyInterval: TimeInterval,
        idleInterval: TimeInterval
    ) -> Bool {
        sinceLastAttempt >= (isBusy ? busyInterval : idleInterval)
    }

    /// Refresh because the user just opened the notch — but only if the reading
    /// has had time to move.
    ///
    /// The notch unfolds on hover, which happens dozens of times an hour by
    /// accident. Every reading now spawns a vendor CLI, so an unconditional
    /// refresh here would turn a pointer crossing the top of the screen into
    /// seconds of CPU. The window is short enough that anyone who opens the
    /// notch *to check* sees a fresh number, and long enough that brushing past
    /// it repeatedly costs nothing.
    func refreshOnOpen(notWithin window: TimeInterval = 60) {
        let waited = lastAttempt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard waited >= window else { return }
        refreshNow()
    }

    func refreshNow() {
        guard !isRefreshing else {
            Log.usage.notice("refresh skipped: one already in flight")
            return
        }
        isRefreshing = true
        lastAttempt = Date()
        refreshTask = Task { [weak self] in
            await self?.refresh()
            self?.isRefreshing = false
        }
    }

    func refresh() async {
        let live = providers.filter { !disconnected.contains($0.id) }
        refreshing = Set(live.map(\.id))
        defer { refreshing = [] }
        var next: [ProviderSnapshot] = []
        for provider in live {
            next.append(await snapshot(from: provider))
        }
        snapshots = next
    }

    /// Refetch one provider, leaving the others alone.
    ///
    /// Deliberately not routed through `refreshNow`: asking one cell for a fresh
    /// reading should not spend every other provider's rate-limit budget, and
    /// Claude's in particular is easy to exhaust.
    func refresh(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }),
              !disconnected.contains(providerID),
              !refreshing.contains(providerID) else { return }

        refreshing.insert(providerID)
        Task { [weak self] in
            let fresh = await self?.snapshot(from: provider)
            guard let self, let fresh else { return }
            if let index = self.snapshots.firstIndex(where: { $0.id == providerID }) {
                self.snapshots[index] = fresh
            }
            self.lastAttempt = Date()
            // A beat of visible work even when the answer was instant: a spinner
            // that flashes for one frame reads as a glitch, not as a refresh.
            try? await Task.sleep(nanoseconds: 380_000_000)
            self.refreshing.remove(providerID)
        }
    }

    /// Sign out of one provider: discard anything of its account that this app
    /// is holding, and stop reading it.
    ///
    /// Deliberately more than `disconnected` alone. Switching a provider off
    /// stops the *next* read; it leaves the last one archived, so the numbers
    /// come back on the next launch. Someone who presses Sign out means those
    /// numbers to be gone.
    ///
    /// What it cannot do is end the session at the vendor: for every provider
    /// shipping today the credential belongs to Claude Code, Cursor or Codex,
    /// and deleting their keychain item would sign the user out of an app they
    /// did not ask us to touch. `SignInRoute.signOutCaveat` says so on the row.
    func signOut(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }

        snapshots.removeAll { $0.id == providerID }
        lastGood.removeValue(forKey: providerID)
        archive.forget(providerID)

        Task { await provider.signOut() }
    }

    /// Take the user to wherever this provider's account is signed into.
    ///
    /// Three different places, because the providers differ in what they own: a
    /// `WebSessionProvider` presents its own modal, Cursor and Codex hold the
    /// credential in their app so the app is launched, and Claude Code is a
    /// command with nothing to open — the row's guidance is all there is.
    /// Returns whether anything was actually opened, so the sheet can say so
    /// when nothing was.
    @discardableResult
    func signIn(providerID: String) -> Bool {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return false }

        // Already holding a usable credential: connecting is the whole job, and
        // throwing up a sign-in window over a signed-in account is just noise.
        if provider.account() != nil {
            refresh(providerID: providerID)
            return true
        }

        return openAccountSource(providerID: providerID)
    }

    /// Take the user to where this provider's account is *changed*.
    ///
    /// Same destination as signing in, but unconditional: switching accounts is
    /// something you do while already signed in, so the shortcut `signIn` takes
    /// when a credential exists is exactly wrong here.
    ///
    /// Codenotch cannot switch the account itself. The credential belongs to
    /// Claude Code, Cursor or Codex, and the most this can honestly do is open
    /// the thing that owns it.
    @discardableResult
    func openAccountSource(providerID: String) -> Bool {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return false }

        switch provider.signInRoute {
        case .modal:
            provider.presentSignIn()
            return true
        case .openApp(let bundleID, _):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return false }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return true
        case .guidance:
            // Claude Code: nothing to open. The row's guidance is the whole
            // answer, so the sheet has to show it rather than pretend.
            return false
        }
    }

    private func snapshot(from provider: UsageProvider) async -> ProviderSnapshot {
        do {
            let fresh = try await provider.fetchSnapshot()
            lastGood[provider.id] = (fresh, Date())
            archive.save(lastGood)
            Log.usage.debug("\(provider.id, privacy: .public): \(fresh.windows.count) window(s)")
            return fresh
        } catch {
            Log.usage.error("\(provider.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return degraded(provider: provider, error: error)
        }
    }

    /// A failed fetch never invents a number: it either re-shows the last good
    /// one marked stale, or shows the cell with no reading at all.
    private func degraded(provider: UsageProvider, error: Error) -> ProviderSnapshot {
        let status = Self.status(for: error)

        // Some failures are statements about the account rather than a hiccup:
        // signed out, or a plan that meters nothing. Re-showing an old reading
        // through one of those would present a number that is no longer true —
        // and, after an endpoint change, one that came from somewhere we no
        // longer read. So the remembered reading is dropped, not dimmed.
        if Self.supersedesHistory(status) {
            lastGood[provider.id] = nil
            archive.save(lastGood)
            var empty = Self.placeholder(provider)
            empty.status = status
            return empty
        }

        guard let previous = lastGood[provider.id] else {
            var empty = Self.placeholder(provider)
            empty.status = status
            return empty
        }

        // A stale-but-recent reading is still worth showing undimmed; past the
        // window it gets marked, and the ring dims.
        let age = Date().timeIntervalSince(previous.fetchedAt)
        var snapshot = previous.snapshot
        snapshot.status = age > staleAfter ? .stale(since: previous.fetchedAt) : previous.snapshot.status
        return snapshot
    }

    /// True when the new status makes any remembered reading untrue rather than
    /// merely old.
    static func supersedesHistory(_ status: ProviderStatus) -> Bool {
        switch status {
        case .needsAuth, .unsupported: return true
        case .ok, .stale, .error:      return false
        }
    }

    /// Exposed for the tests: the store never invents a reading, so what a
    /// failure looks like is worth pinning down.
    static func statusForTesting(_ error: Error) -> ProviderStatus { status(for: error) }

    /// Exposed so a test can hold the shipped defaults to the margin they are
    /// supposed to keep, without re-typing the numbers on both sides.
    var staleAfterForTesting: TimeInterval { staleAfter }
    var idleRefreshIntervalForTesting: TimeInterval { idleRefreshInterval }
    var busyRefreshIntervalForTesting: TimeInterval { busyRefreshInterval }

    private static func status(for error: Error) -> ProviderStatus {
        switch error {
        case UsageProviderError.needsAuth:
            return .needsAuth
        case UsageProviderError.notAnswering:
            // Ages the reading rather than discarding it: the number was true
            // when it was taken, and the tool will answer again the next time
            // it is running.
            return .stale(since: Date())
        case UsageProviderError.rateLimited:
            // Not an error the user can do anything about, and the last good
            // reading is still roughly true, so it reads as staleness.
            return .stale(since: Date())
        case UsageProviderError.nothingMetered(let why),
             UsageProviderError.unavailable(let why):
            return .unsupported(why)
        case UsageProviderError.badResponse(let code):
            return .error("HTTP \(code)")
        default:
            return .error((error as NSError).localizedDescription)
        }
    }

    private static func placeholder(_ provider: UsageProvider) -> ProviderSnapshot {
        ProviderSnapshot(
            id: provider.id,
            displayName: provider.displayName,
            glyph: provider.glyph,
            fidelity: .official,
            status: .stale(since: .distantPast),
            windows: []
        )
    }
}
