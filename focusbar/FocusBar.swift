// FocusBar: a small Pomodoro timer that lives in the macOS menu bar.
// Build with ./build.sh (needs only Apple's command line tools).

import AppKit
import SwiftUI
import UserNotifications

// MARK: - Model

enum Phase { case idle, focus, rest }

struct Preset: Identifiable, Equatable {
    let id: String
    let focusMinutes: Int
    let restMinutes: Int

    static let all = [
        Preset(id: "25 / 5", focusMinutes: 25, restMinutes: 5),
        Preset(id: "50 / 10", focusMinutes: 50, restMinutes: 10),
    ]
}

struct ParkedItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
}

@MainActor
final class FocusModel: ObservableObject {
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remaining = 0          // seconds left in the current phase
    @Published private(set) var paused = false
    @Published private(set) var task = ""
    @Published private(set) var parked: [ParkedItem] = []
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

    private let defaults: UserDefaults
    private var endsAt: Date?
    private var timer: Timer?

    init(defaults: UserDefaults = .standard, live: Bool = true, now: Date = Date()) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "preset") ?? ""
        presetID = Preset.all.contains { $0.id == saved } ? saved : Preset.all[0].id
        chimeOn = (defaults.object(forKey: "chimeOn") as? Bool) ?? true
        let savedSound = defaults.string(forKey: "chimeSound") ?? ""
        chimeSound = Chime.sounds.contains(savedSound) ? savedSound : Chime.sounds[0]
        task = defaults.string(forKey: "task") ?? ""
        if let data = defaults.data(forKey: "parked"),
           let items = try? JSONDecoder().decode([ParkedItem].self, from: data) {
            parked = items
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

    var preset: Preset { Preset.all.first { $0.id == presetID } ?? Preset.all[0] }

    var clock: String {
        let seconds = phase == .idle ? preset.focusMinutes * 60 : remaining
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var menuTitle: String {
        switch phase {
        case .idle: return "🍅"
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
        phase = .focus
        begin(seconds: preset.focusMinutes * 60, now: now)
    }

    func togglePause(now: Date = Date()) {
        guard phase != .idle else { return }
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
        if left != remaining { remaining = left }
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

    private func finishPhase(now: Date) {
        switch phase {
        case .idle: break
        case .focus:
            doneToday += 1
            defaults.set(doneToday, forKey: "done")
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
}

// MARK: - Alerts

/// Plays a macOS system sound a few times in a row, so it is hard to miss.
@MainActor
enum Chime {
    static let sounds = ["Glass", "Hero", "Ping", "Purr", "Submarine", "Tink"]
    static let rings = 3
    static let spacing = 0.9  // seconds between rings

    static func play(_ name: String) {
        for ring in 0..<rings {
            DispatchQueue.main.asyncAfter(deadline: .now() + spacing * Double(ring)) {
                // A fresh copy per ring, so rings can overlap if the sound is long.
                (NSSound(named: name)?.copy() as? NSSound)?.play()
            }
        }
    }
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
    @FocusState private var taskFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.phase == .idle { idleHeader } else { runningHeader }
            Divider()
            parkSection
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

    private var runningHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.phase == .focus ? "FOCUS" : "BREAK")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.phase == .focus ? model.task : "Stand up and look away from the screen.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
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
                ForEach(Preset.all) { Text($0.id).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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

    let m = FocusModel(defaults: defaults, live: false, now: t0)
    m.onAlert = { title, _, sound in
        alerts.append(title)
        chimes.append(sound)
    }

    check(m.phase == .idle && m.menuTitle == "🍅", "starts idle")
    check(m.chimeOn && m.chimeSound == "Glass", "chime is on by default")
    check(Chime.sounds.allSatisfy { NSSound(named: $0) != nil }, "every chime sound exists on this Mac")
    m.start(task: "   ", now: t0)
    check(m.phase == .idle, "blank task does not start a session")

    m.start(task: " write intro ", now: t0)
    check(m.phase == .focus && m.remaining == 1500 && m.task == "write intro", "start begins 25 min focus")
    check(m.menuTitle == "🍅 25:00", "menu bar shows countdown")

    m.tick(now: at(60))
    check(m.remaining == 1440, "counts down")

    m.togglePause(now: at(60))
    m.tick(now: at(600))
    check(m.remaining == 1440 && m.menuTitle == "⏸ 24:00", "pause holds the time")

    m.togglePause(now: at(600))
    m.tick(now: at(600 + 1439))
    check(m.phase == .focus && m.remaining == 1, "resume continues from the paused time")

    m.park(" check email ")
    m.tick(now: at(600 + 1440))
    check(m.phase == .rest && m.remaining == 300 && m.doneToday == 1, "focus end counts a session and starts the break")
    check(alerts == ["Focus session done"], "alert at focus end")
    check(chimes == ["Glass"], "chime rings at focus end")
    check(m.menuTitle == "☕ 05:00", "menu bar shows break")

    let reloaded = FocusModel(defaults: defaults, live: false, now: at(2100))
    check(reloaded.doneToday == 1 && reloaded.parked.map(\.text) == ["check email"] && reloaded.task == "write intro",
          "count, parked items and task survive a relaunch")

    m.tick(now: at(600 + 1440 + 300))
    check(m.phase == .idle && alerts.last == "Break over", "break end returns to idle with an alert")
    check(chimes.count == 2 && chimes.last == "Glass", "chime rings at break end")

    m.chimeSound = "Submarine"
    m.chimeOn = false
    let reloadedChime = FocusModel(defaults: defaults, live: false, now: at(2200))
    check(!reloadedChime.chimeOn && reloadedChime.chimeSound == "Submarine", "chime settings survive a relaunch")
    m.start(task: "quiet", now: at(2200))
    m.tick(now: at(2200 + 1500))
    check(chimes.count == 3 && chimes.last == .some(nil), "no chime when muted")
    m.reset()
    m.chimeOn = true

    m.presetID = "50 / 10"
    m.start(task: "deep work", now: at(3000))
    check(m.remaining == 3000, "50 / 10 preset gives a 50 min focus")
    m.skip(now: at(3010))
    // Two sessions completed so far (the second during the muted check).
    check(m.phase == .rest && m.remaining == 600 && m.doneToday == 2, "skip goes to the break without counting")
    m.skip(now: at(3020))
    check(m.phase == .idle, "skip during the break returns to idle")

    m.start(task: "again", now: at(3100))
    m.reset()
    check(m.phase == .idle && m.doneToday == 2, "reset returns to idle")

    m.removeParked(m.parked[0])
    check(m.parked.isEmpty, "parked item can be removed")

    m.tick(now: at(2 * 86_400))
    check(m.doneToday == 0, "session count resets on a new day")

    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    return failures == 0
}
