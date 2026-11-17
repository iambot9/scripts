// FocusBar: a small Pomodoro timer that lives in the macOS menu bar.
// Build with ./build.sh (needs only Apple's command line tools).

import AppKit
import SwiftUI
import UserNotifications

// MARK: - Model

enum Phase { case idle, countdown, focus, rest }

struct Preset: Identifiable, Equatable {
    let id: String
    let focusMinutes: Int
    let restMinutes: Int

    // Shortest first; each keeps the same 5:1 focus:break ratio.
    static let all = [
        Preset(id: "10 / 2", focusMinutes: 10, restMinutes: 2),
        Preset(id: "15 / 3", focusMinutes: 15, restMinutes: 3),
        Preset(id: "25 / 5", focusMinutes: 25, restMinutes: 5),
        Preset(id: "45 / 9", focusMinutes: 45, restMinutes: 9),
        Preset(id: "50 / 10", focusMinutes: 50, restMinutes: 10),
    ]

    /// The classic Pomodoro, used when nothing is saved yet. Named rather than
    /// positional so reordering `all` cannot change the default.
    static let fallback = all.first { $0.id == "25 / 5" } ?? all[0]
}

struct ParkedItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
}

/// One finished focus session. Skipped and reset sessions are not recorded,
/// so this matches what the daily count counts.
struct SessionRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var task: String
    var finishedAt: Date
    var focusMinutes: Int
}

/// Shown in the panel while a focus session runs. Deliberately unattributed:
/// most circulating "motivational quotes" are misattributed, and inventing a
/// source would be worse than having none.
enum Quotes {
    static let all = [
        "One thing. Then the next.",
        "Done beats perfect.",
        "The hard part was starting. You already did.",
        "Small steps still cover ground.",
        "Protect this hour. It will not come back.",
        "Attention is the whole game.",
        "You do not need to feel ready.",
        "Finish the sentence, then the paragraph.",
        "Momentum is built, not found.",
        "Depth beats speed.",
        "Close the tabs. Keep the thread.",
        "Progress hides in boring minutes.",
        "Slow is steady. Steady is fast.",
        "The work is the reward.",
        "Nobody is coming. That is fine, you are here.",
        "Begin badly. Fix it later.",
    ]

    /// A different line each session, so it never repeats back to back.
    static func next(after current: String) -> String {
        guard all.count > 1 else { return all[0] }
        var pick = current
        while pick == current { pick = all.randomElement()! }
        return pick
    }
}

@MainActor
final class FocusModel: ObservableObject {
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remaining = 0          // seconds left in the current phase
    @Published private(set) var paused = false
    @Published private(set) var task = ""
    @Published private(set) var quote = ""
    @Published private(set) var parked: [ParkedItem] = []
    @Published private(set) var history: [SessionRecord] = []
    @Published private(set) var doneToday = 0
    @Published var presetID: String {
        didSet { defaults.set(presetID, forKey: "preset") }
    }
    @Published var chimeOn: Bool {
        didSet { defaults.set(chimeOn, forKey: "chimeOn") }
    }
    @Published var chimeSound: String {
        didSet { defaults.set(chimeSound, forKey: "chimeSound") }
    }

    /// Called when a phase ends: (title, body, chime sound or nil when muted).
    var onAlert: ((String, String, String?) -> Void)?

    /// Called once per second of the pre-roll countdown, and again with 0 the
    /// moment focus begins. The second value is the sound, or nil when muted.
    var onCountdown: ((Int, String?) -> Void)?

    private let defaults: UserDefaults
    private var endsAt: Date?
    private var timer: Timer?
    private var runningFocusMinutes = 0

    /// Keeps the saved log from growing without limit.
    static let historyLimit = 50

    /// Seconds of audible lead-in before a focus session starts.
    static let countdownSeconds = 5

    init(defaults: UserDefaults = .standard, live: Bool = true, now: Date = Date()) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "preset") ?? ""
        presetID = Preset.all.contains { $0.id == saved } ? saved : Preset.fallback.id
        chimeOn = (defaults.object(forKey: "chimeOn") as? Bool) ?? true
        let savedSound = defaults.string(forKey: "chimeSound") ?? ""
        chimeSound = Chime.sounds.contains(savedSound) ? savedSound : Chime.sounds[0]
        task = defaults.string(forKey: "task") ?? ""
        if let data = defaults.data(forKey: "parked"),
           let items = try? JSONDecoder().decode([ParkedItem].self, from: data) {
            parked = items
        }
        if let data = defaults.data(forKey: "history"),
           let items = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            history = items
        }
        doneToday = defaults.integer(forKey: "done")
        refreshDay(now: now)

        if live {
            // .common mode keeps the countdown ticking while the panel is open.
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(now: Date()) }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    var preset: Preset { Preset.all.first { $0.id == presetID } ?? Preset.fallback }

    var clock: String {
        let seconds = phase == .idle ? preset.focusMinutes * 60 : remaining
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var menuTitle: String {
        switch phase {
        case .idle: return "🍅"
        case .countdown: return "⏳ \(remaining)"
        case .focus: return (paused ? "⏸ " : "🍅 ") + clock
        case .rest: return (paused ? "⏸ " : "☕ ") + clock
        }
    }

    // MARK: Session control

    func start(task newTask: String, now: Date = Date()) {
        let trimmed = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task = trimmed
        defaults.set(trimmed, forKey: "task")
        quote = Quotes.next(after: quote)
        phase = .countdown
        begin(seconds: Self.countdownSeconds, now: now)
        onCountdown?(Self.countdownSeconds, tick)
    }

    func togglePause(now: Date = Date()) {
        guard phase == .focus || phase == .rest else { return }
        if paused {
            endsAt = now.addingTimeInterval(TimeInterval(remaining))
            paused = false
        } else {
            remaining = secondsLeft(now: now)
            endsAt = nil
            paused = true
        }
    }

    /// Focus -> break without counting the session; break -> idle.
    func skip(now: Date = Date()) {
        switch phase {
        case .idle: break
        case .countdown: goIdle()
        case .focus:
            phase = .rest
            begin(seconds: preset.restMinutes * 60, now: now)
        case .rest: goIdle()
        }
    }

    func reset() { goIdle() }

    func tick(now: Date) {
        refreshDay(now: now)
        guard phase != .idle, !paused else { return }
        let left = secondsLeft(now: now)
        if left != remaining {
            remaining = left
            if phase == .countdown, left > 0 { onCountdown?(left, tick) }
        }
        if left == 0 { finishPhase(now: now) }
    }

    // MARK: Parked distractions

    func park(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        parked.append(ParkedItem(text: trimmed))
        saveParked()
    }

    func removeParked(_ item: ParkedItem) {
        parked.removeAll { $0.id == item.id }
        saveParked()
    }

    func clearParked() {
        parked = []
        saveParked()
    }

    // MARK: Session history

    func clearHistory() {
        history = []
        saveHistory()
    }

    /// Oldest first, which is the order you want when pasting into a timesheet.
    var historyReport: String {
        history
            .map { "- \($0.task) (\($0.focusMinutes) min, \(Stamp.full.string(from: $0.finishedAt)))" }
            .joined(separator: "\n")
    }

    // MARK: Internals

    private func begin(seconds: Int, now: Date) {
        remaining = seconds
        endsAt = now.addingTimeInterval(TimeInterval(seconds))
        paused = false
    }

    private func goIdle() {
        phase = .idle
        remaining = 0
        endsAt = nil
        paused = false
    }

    private func secondsLeft(now: Date) -> Int {
        guard let endsAt else { return remaining }
        return max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
    }

    private var chime: String? { chimeOn ? chimeSound : nil }
    private var tick: String? { chimeOn ? Chime.tickSound : nil }

    private func finishPhase(now: Date) {
        switch phase {
        case .idle: break
        case .countdown:
            phase = .focus
            runningFocusMinutes = preset.focusMinutes
            begin(seconds: preset.focusMinutes * 60, now: now)
            onCountdown?(0, chime)   // the "go"
        case .focus:
            doneToday += 1
            defaults.set(doneToday, forKey: "done")
            record(task: task, at: now, minutes: runningFocusMinutes)
            let note = parked.isEmpty
                ? "Step away from the screen."
                : "Step away, then review \(parked.count) parked item\(parked.count == 1 ? "" : "s")."
            onAlert?("Focus session done", note, chime)
            phase = .rest
            begin(seconds: preset.restMinutes * 60, now: now)
        case .rest:
            onAlert?("Break over", "Name the next task and start again.", chime)
            goIdle()
        }
    }

    /// Resets the session count when the calendar day changes.
    private func refreshDay(now: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let day = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        guard defaults.string(forKey: "day") != day else { return }
        defaults.set(day, forKey: "day")
        defaults.set(0, forKey: "done")
        if doneToday != 0 { doneToday = 0 }
    }

    private func saveParked() {
        defaults.set(try? JSONEncoder().encode(parked), forKey: "parked")
    }

    private func record(task: String, at date: Date, minutes: Int) {
        history.append(SessionRecord(task: task, finishedAt: date, focusMinutes: minutes))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        saveHistory()
    }

    private func saveHistory() {
        defaults.set(try? JSONEncoder().encode(history), forKey: "history")
    }
}

// MARK: - Alerts

/// Plays a macOS system sound a few times in a row, so it is hard to miss.
@MainActor
enum Chime {
    static let sounds = ["Glass", "Hero", "Ping", "Purr", "Submarine", "Tink"]
    /// Short and dry, so five in a row do not become a racket.
    static let tickSound = "Tink"
    static let rings = 3
    static let spacing = 0.9  // seconds between rings

    /// One ring, for the countdown.
    static func once(_ name: String) {
        (NSSound(named: name)?.copy() as? NSSound)?.play()
    }

    static func play(_ name: String) {
        for ring in 0..<rings {
            DispatchQueue.main.asyncAfter(deadline: .now() + spacing * Double(ring)) {
                // A fresh copy per ring, so rings can overlap if the sound is long.
                (NSSound(named: name)?.copy() as? NSSound)?.play()
            }
        }
    }
}

/// Locale-aware timestamps for the history list.
@MainActor
enum Stamp {
    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        // Day, month and time, ordered to suit the locale.
        f.setLocalizedDateFormatFromTemplate("dMMMjmm")
        return f
    }()

    static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// Date and time together, so an entry is never ambiguous about its day.
    static func short(_ when: Date) -> String { dateTime.string(from: when) }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    // Show the banner even though a menu bar app always counts as "in front".
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}

@MainActor
enum Alerts {
    static let delegate = NotificationDelegate()
    // Notifications need a real app bundle; the sound works either way.
    static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    static func setUp() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func fire(title: String, body: String, sound: String?) {
        if let sound { Chime.play(sound) }
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}

// MARK: - Panel

struct PanelView: View {
    @EnvironmentObject var model: FocusModel
    @State private var taskDraft = ""
    @State private var parkDraft = ""
    @State private var showParked = false
    @State private var showHistory = false
    @FocusState private var taskFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .idle: idleHeader
            case .countdown: countdownHeader
            case .focus, .rest: runningHeader
            }
            Divider()
            parkSection
            Divider()
            historySection
            Divider()
            chimeRow
            footer
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            taskDraft = model.task
            taskFocused = model.phase == .idle
        }
        .onChange(of: model.phase) { _, phase in
            // Open the parked list at the break, when it is time to review it.
            if phase == .rest && !model.parked.isEmpty { showParked = true }
        }
    }

    private var idleHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What is the one thing?").font(.headline)
            TextField("e.g. draft the intro section", text: $taskDraft)
                .textFieldStyle(.roundedBorder)
                .focused($taskFocused)
                .onSubmit(startSession)
            HStack {
                Button("Start \(model.preset.focusMinutes) min focus", action: startSession)
                    .buttonStyle(.borderedProminent)
                    .disabled(taskDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                sessionDots
            }
        }
    }

    private var countdownHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STARTING").font(.caption).foregroundStyle(.secondary)
            Text(model.task).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text("\(model.remaining)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.remaining)
                Text("settle in").font(.caption).foregroundStyle(.secondary)
                Spacer()
                sessionDots
            }
            Button("Cancel") { model.reset() }
        }
    }

    private var runningHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.phase == .focus ? "FOCUS" : "BREAK")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.phase == .focus ? model.task : "Stand up and look away from the screen.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if model.phase == .focus, !model.quote.isEmpty {
                Text(model.quote)
                    .font(.callout).italic().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(model.clock)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                sessionDots
            }
            HStack {
                Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
                Button("Skip") { model.skip() }
                Button("Reset") { model.reset() }
            }
        }
    }

    private var sessionDots: some View {
        let done = model.doneToday
        let dots = String(repeating: "●", count: min(done, 8))
            + String(repeating: "○", count: max(0, 4 - done))
        return Text("\(dots)  \(done) today")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var parkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Park a distraction, then press Return", text: $parkDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    model.park(parkDraft)
                    parkDraft = ""
                }
            DisclosureGroup("Parked (\(model.parked.count))", isExpanded: $showParked) {
                if model.parked.isEmpty {
                    Text("Nothing parked.").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.parked) { item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.text).font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Button {
                                        model.removeParked(item)
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove")
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                    HStack {
                        Button("Copy all") {
                            let text = model.parked.map { "- \($0.text)" }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        Button("Clear") { model.clearParked() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var historySection: some View {
        DisclosureGroup("History (\(model.history.count))", isExpanded: $showHistory) {
            if model.history.isEmpty {
                Text("No finished sessions yet.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        // Newest first: the most recent session is the one you
                        // are most likely to be looking for.
                        ForEach(model.history.reversed()) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.task).font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(Stamp.short(item.finishedAt)) · \(item.focusMinutes) min")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 2)
                        }
                    }
                }
                .frame(maxHeight: 140)
                HStack {
                    Button("Copy all") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.historyReport, forType: .string)
                    }
                    Button("Clear") { model.clearHistory() }
                }
                .controlSize(.small)
            }
        }
    }

    private var chimeRow: some View {
        HStack {
            Toggle("Chime", isOn: $model.chimeOn)
                .toggleStyle(.switch)
                .controlSize(.small)
            Picker("Sound", selection: $model.chimeSound) {
                ForEach(Chime.sounds, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            .disabled(!model.chimeOn)
            .onChange(of: model.chimeSound) { _, name in NSSound(named: name)?.play() }
            Spacer()
            Button {
                Chime.play(model.chimeSound)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help("Play the chime")
        }
    }

    private var footer: some View {
        HStack {
            Picker("Focus / break", selection: $model.presetID) {
                ForEach(Preset.all) { Text("\($0.id) min").tag($0.id) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 130)
            .help("Focus and break minutes. A change applies from the next session.")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }

    private func startSession() {
        model.start(task: taskDraft)
    }
}

// MARK: - App

struct FocusBarApp: App {
    @StateObject private var model: FocusModel = {
        let model = FocusModel()
        model.onAlert = { Alerts.fire(title: $0, body: $1, sound: $2) }
        model.onCountdown = { _, sound in if let sound { Chime.once(sound) } }
        Alerts.setUp()
        return model
    }()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            Text(model.menuTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

@main
enum Main {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(selfTest() ? 0 : 1)
        }
        FocusBarApp.main()
    }
}

// MARK: - Self-test (./FocusBar --selftest)

/// Drives the timer logic with simulated time; touches no real settings.
@MainActor
func selfTest() -> Bool {
    let suite = "focusbar.selftest"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    let defaults = UserDefaults(suiteName: suite)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
        if !ok { failures += 1 }
    }

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    var alerts: [String] = []
    var chimes: [String?] = []
    var cues: [(Int, String?)] = []

    let m = FocusModel(defaults: defaults, live: false, now: t0)
    m.onAlert = { title, _, sound in
        alerts.append(title)
        chimes.append(sound)
    }
    m.onCountdown = { left, sound in cues.append((left, sound)) }

    let lead = Double(FocusModel.countdownSeconds)

    /// Starts a session and runs the countdown out, returning the moment focus began.
    @discardableResult
    func launch(_ task: String, at start: TimeInterval) -> TimeInterval {
        m.start(task: task, now: at(start))
        m.tick(now: at(start + lead))
        return start + lead
    }

    // MARK: Setup

    check(m.phase == .idle && m.menuTitle == "🍅", "starts idle")
    check(m.chimeOn && m.chimeSound == "Glass", "chime is on by default")
    check(m.presetID == "25 / 5", "defaults to the 25 / 5 preset")
    check(Preset.all.map(\.id) == ["10 / 2", "15 / 3", "25 / 5", "45 / 9", "50 / 10"],
          "five presets, shortest first")
    check(Preset.all.allSatisfy { $0.focusMinutes == $0.restMinutes * 5 },
          "every preset keeps the 5:1 focus:break ratio")
    check(Chime.sounds.allSatisfy { NSSound(named: $0) != nil }, "every chime sound exists on this Mac")
    check(NSSound(named: Chime.tickSound) != nil, "the countdown tick sound exists on this Mac")
    check(Quotes.all.count >= 8 && Quotes.all.allSatisfy { !$0.isEmpty }, "there are quotes to show")

    m.start(task: "   ", now: t0)
    check(m.phase == .idle, "blank task does not start a session")

    // MARK: The 5 second lead-in

    m.start(task: " write intro ", now: t0)
    check(m.phase == .countdown && m.remaining == 5 && m.task == "write intro",
          "a session opens with a 5 second countdown, not focus")
    check(m.menuTitle == "⏳ 5", "menu bar counts the lead-in down")
    check(cues.map(\.0) == [5], "the countdown is cued as it starts")
    let opening = m.quote
    check(Quotes.all.contains(opening), "a quote is picked for the session")

    m.togglePause(now: at(1))
    check(m.phase == .countdown && !m.paused, "the lead-in cannot be paused")

    for second in 1...4 { m.tick(now: at(TimeInterval(second))) }
    check(cues.map(\.0) == [5, 4, 3, 2, 1], "one cue per second of the lead-in")
    check(cues.allSatisfy { $0.1 == Chime.tickSound }, "the lead-in ticks")
    check(m.phase == .countdown, "still counting down at 1")

    m.tick(now: at(lead))
    check(m.phase == .focus && m.remaining == 1500, "focus starts when the lead-in ends")
    check(cues.last!.0 == 0 && cues.last!.1 == "Glass", "the start of focus is cued with the chime")
    check(m.menuTitle == "🍅 25:00", "menu bar shows the countdown")

    // MARK: A full session

    m.tick(now: at(65))
    check(m.remaining == 1440, "counts down")

    m.togglePause(now: at(65))
    m.tick(now: at(605))
    check(m.remaining == 1440 && m.menuTitle == "⏸ 24:00", "pause holds the time")

    m.togglePause(now: at(605))
    m.tick(now: at(2044))
    check(m.phase == .focus && m.remaining == 1, "resume continues from the paused time")

    m.park(" check email ")
    m.tick(now: at(2045))
    check(m.phase == .rest && m.remaining == 300 && m.doneToday == 1,
          "focus end counts a session and starts the break")
    check(alerts == ["Focus session done"], "alert at focus end")
    check(chimes == ["Glass"], "chime rings at focus end")
    check(m.menuTitle == "☕ 05:00", "menu bar shows break")

    let reloaded = FocusModel(defaults: defaults, live: false, now: at(2100))
    check(reloaded.doneToday == 1 && reloaded.parked.map(\.text) == ["check email"]
            && reloaded.task == "write intro",
          "count, parked items and task survive a relaunch")

    m.tick(now: at(2345))
    check(m.phase == .idle && alerts.last == "Break over", "break end returns to idle with an alert")
    check(chimes.count == 2 && chimes.last == "Glass", "chime rings at break end")

    // MARK: Muting

    m.chimeSound = "Submarine"
    m.chimeOn = false
    let reloadedChime = FocusModel(defaults: defaults, live: false, now: at(2400))
    check(!reloadedChime.chimeOn && reloadedChime.chimeSound == "Submarine",
          "chime settings survive a relaunch")

    launch("quiet", at: 2500)
    check(cues.suffix(2).allSatisfy { $0.1 == nil }, "muting the chime also silences the lead-in")
    m.tick(now: at(2505 + 1500))
    check(chimes.count == 3 && chimes.last == .some(nil), "no chime when muted")
    m.reset()
    m.chimeOn = true
    check(m.quote != opening, "a new session picks a different quote")

    // MARK: Presets

    m.presetID = "50 / 10"
    launch("deep work", at: 4100)
    check(m.remaining == 3000, "50 / 10 preset gives a 50 min focus")
    m.skip(now: at(4110))
    check(m.phase == .rest && m.remaining == 600 && m.doneToday == 2,
          "skip goes to the break without counting")
    m.skip(now: at(4120))
    check(m.phase == .idle, "skip during the break returns to idle")

    m.presetID = "15 / 3"
    launch("quick pass", at: 4200)
    check(m.remaining == 900 && m.menuTitle == "🍅 15:00", "15 / 3 preset gives a 15 min focus")
    m.tick(now: at(5105))
    check(m.phase == .rest && m.remaining == 180 && m.doneToday == 3,
          "15 / 3 preset counts the session and starts a 3 min break")
    m.tick(now: at(5285))
    check(m.phase == .idle, "15 / 3 break ends back at idle")
    check(FocusModel(defaults: defaults, live: false, now: at(5400)).presetID == "15 / 3",
          "chosen preset survives a relaunch")

    m.presetID = "10 / 2"
    launch("triage", at: 6000)
    check(m.remaining == 600, "10 / 2 preset gives a 10 min focus")
    m.tick(now: at(6605))
    check(m.phase == .rest && m.remaining == 120, "10 / 2 preset gives a 2 min break")
    m.skip(now: at(6650))

    m.presetID = "45 / 9"
    launch("write spec", at: 7000)
    check(m.remaining == 2700, "45 / 9 preset gives a 45 min focus")
    m.tick(now: at(9705))
    check(m.phase == .rest && m.remaining == 540, "45 / 9 preset gives a 9 min break")
    m.skip(now: at(9750))

    // MARK: Cancelling and resetting

    m.start(task: "again", now: at(9800))
    check(m.phase == .countdown, "a new session begins with the lead-in")
    m.skip(now: at(9802))
    check(m.phase == .idle && m.doneToday == 5, "the lead-in can be cancelled before focus starts")

    launch("and again", at: 9900)
    m.reset()
    check(m.phase == .idle && m.doneToday == 5, "reset returns to idle")

    // MARK: History

    check(m.history.map(\.task) == ["write intro", "quiet", "quick pass", "triage", "write spec"],
          "history records finished sessions, leaving out skipped, cancelled and reset ones")
    check(m.history.map(\.focusMinutes) == [25, 25, 15, 10, 45],
          "history records the length each session actually ran")
    check(m.history.last?.finishedAt == at(9705), "history records when a session finished")
    let stamped = at(9705)
    check(Stamp.short(stamped) != Stamp.short(stamped.addingTimeInterval(3600)),
          "the history stamp carries the time")
    check(Stamp.short(stamped) != Stamp.short(stamped.addingTimeInterval(86_400)),
          "the history stamp carries the date as well as the time")
    let reloadedHistory = FocusModel(defaults: defaults, live: false, now: at(9900))
    check(reloadedHistory.history == m.history, "history survives a relaunch")

    m.presetID = "10 / 2"
    for i in 0..<FocusModel.historyLimit {
        let base = 10_000 + Double(i) * 1000
        m.start(task: "filler \(i)", now: at(base))
        m.tick(now: at(base + lead))        // lead-in ends, focus starts
        m.tick(now: at(base + lead + 600))  // focus ends
        m.skip(now: at(base + 700))         // leave the break
    }
    check(m.history.count == FocusModel.historyLimit, "history stops growing at the limit")
    check(m.history.first?.task == "filler 0", "the oldest entries drop off first")

    m.clearHistory()
    check(m.history.isEmpty, "history can be cleared")
    check(FocusModel(defaults: defaults, live: false, now: at(60_000)).history.isEmpty,
          "a cleared history stays cleared")

    // MARK: Housekeeping

    m.removeParked(m.parked[0])
    check(m.parked.isEmpty, "parked item can be removed")

    m.tick(now: at(2 * 86_400))
    check(m.doneToday == 0, "session count resets on a new day")

    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    return failures == 0
}
