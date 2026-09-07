import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import SwiftUI

enum GestureSlot: String, CaseIterable, Codable, Identifiable {
    case single
    case double
    case triple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "Single tap"
        case .double: "Double tap"
        case .triple: "Triple tap"
        }
    }
}

struct KeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var label: String
    var toggle: Bool
}

final class DetectorSettings: ObservableObject {
    @Published var sensitivity: Double { didSet { persist() } }
    @Published var debounceMilliseconds: Double { didSet { persist() } }
    @Published var gestureWindowMilliseconds: Double { didSet { persist() } }

    init() {
        let defaults = UserDefaults.standard
        sensitivity = defaults.object(forKey: "detector-sensitivity") as? Double ?? 0.08
        debounceMilliseconds = defaults.object(forKey: "detector-debounce-ms") as? Double ?? 120
        gestureWindowMilliseconds = defaults.object(forKey: "detector-window-ms") as? Double ?? 400
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(sensitivity, forKey: "detector-sensitivity")
        defaults.set(debounceMilliseconds, forKey: "detector-debounce-ms")
        defaults.set(gestureWindowMilliseconds, forKey: "detector-window-ms")
    }
}

final class BindingStore: ObservableObject {
    @Published var bindings: [GestureSlot: KeyBinding] {
        didSet {
            onMutation?()
            save()
        }
    }

    var onMutation: (() -> Void)?

    private let defaultsKey = "gesture-bindings"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([String: KeyBinding].self, from: data) {
            var resolved = saved
            if !UserDefaults.standard.bool(forKey: "single-tap-option-migrated"),
               let binding = saved[GestureSlot.single.rawValue], binding.keyCode == 105, binding.label == "F13" {
                resolved[GestureSlot.single.rawValue] = Self.defaultBinding(for: .single)
                UserDefaults.standard.set(true, forKey: "single-tap-option-migrated")
            }
            bindings = Dictionary(uniqueKeysWithValues: GestureSlot.allCases.map { slot in
                (slot, resolved[slot.rawValue] ?? Self.defaultBinding(for: slot))
            })
            save()
        } else {
            bindings = [
                .single: KeyBinding(keyCode: 58, label: "Option", toggle: true),
                .double: KeyBinding(keyCode: 107, label: "F14", toggle: false),
                .triple: KeyBinding(keyCode: 113, label: "F15", toggle: false)
            ]
        }
    }

    subscript(slot: GestureSlot) -> KeyBinding {
        get { bindings[slot] ?? Self.defaultBinding(for: slot) }
        set { bindings[slot] = newValue }
    }

    private func save() {
        let values = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func defaultBinding(for slot: GestureSlot) -> KeyBinding {
        switch slot {
        case .single: KeyBinding(keyCode: 58, label: "Option", toggle: true)
        case .double: KeyBinding(keyCode: 107, label: "F14", toggle: false)
        case .triple: KeyBinding(keyCode: 113, label: "F15", toggle: false)
        }
    }
}

final class KeySignalEmitter {
    private var heldKeys = Set<UInt16>()

    func emit(_ binding: KeyBinding) {
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            return
        }
        if binding.toggle {
            if heldKeys.contains(binding.keyCode) {
                post(binding.keyCode, down: false)
                heldKeys.remove(binding.keyCode)
            } else {
                post(binding.keyCode, down: true)
                heldKeys.insert(binding.keyCode)
            }
        } else {
            post(binding.keyCode, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.post(binding.keyCode, down: false)
            }
        }
    }

    func releaseAll() {
        for keyCode in heldKeys {
            post(keyCode, down: false)
        }
        heldKeys.removeAll()
    }

    private func post(_ keyCode: UInt16, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
        event.post(tap: .cghidEventTap)
    }
}

final class GestureEngine {
    private let reader: AccelerometerReader
    private let store: BindingStore
    private let emitter: KeySignalEmitter
    private let settings: DetectorSettings
    private var baseline = (x: 0.0, y: 0.0, z: 0.0)
    private var initialized = false
    private var lastImpact: UInt64 = 0
    private var pendingCount = 0
    private var generation = 0

    var onStatus: ((String) -> Void)?

    init(reader: AccelerometerReader, store: BindingStore, emitter: KeySignalEmitter, settings: DetectorSettings) {
        self.reader = reader
        self.store = store
        self.emitter = emitter
        self.settings = settings
        reader.onSample = { [weak self] sample in self?.sample(sample) }
    }

    func start() { reader.start() }
    func stop() { reader.stop() }

    func test(_ slot: GestureSlot) {
        emitter.emit(store[slot])
    }

    private func sample(_ sample: MotionSample) {
        if !initialized {
            baseline = (sample.x, sample.y, sample.z)
            initialized = true
            return
        }
        let alpha = 0.02
        let dx = sample.x - baseline.x
        let dy = sample.y - baseline.y
        let dz = sample.z - baseline.z
        baseline.x += alpha * dx
        baseline.y += alpha * dy
        baseline.z += alpha * dz

        let magnitude = (dx * dx + dy * dy + dz * dz).squareRoot()
        guard magnitude >= settings.sensitivity else { return }
        guard sample.timestamp &- lastImpact > UInt64(settings.debounceMilliseconds * 1_000_000) else { return }
        lastImpact = sample.timestamp
        pendingCount = min(pendingCount + 1, 3)
        generation += 1
        let currentGeneration = generation
        onStatus?("Impact detected (\(pendingCount))")
        if pendingCount == 3 {
            dispatchPending()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.gestureWindowMilliseconds / 1_000) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.dispatchPending()
        }
    }

    private func dispatchPending() {
        let count = pendingCount
        pendingCount = 0
        generation += 1
        let slot: GestureSlot = count == 1 ? .single : count == 2 ? .double : .triple
        emitter.emit(store[slot])
        onStatus?("Dispatched \(slot.title.lowercased())")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = BindingStore()
    private let detectorSettings = DetectorSettings()
    private let reader = AccelerometerReader()
    private let emitter = KeySignalEmitter()
    private var engine: GestureEngine!
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var settingsWindow: NSWindow?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engine = GestureEngine(reader: reader, store: store, emitter: emitter, settings: detectorSettings)
        store.onMutation = { [weak emitter] in emitter?.releaseAll() }
        engine.onStatus = { [weak self] status in self?.statusMenuItem?.title = status }
        reader.onStatus = { [weak self] status in self?.statusMenuItem?.title = status }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "hand.wave.fill", accessibilityDescription: "TapTap") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "👋"
        }
        statusItem.menu = makeMenu()
        engine.start()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "TapTap", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        statusMenuItem = NSMenuItem(title: "Starting sensor…", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        addTestItem(to: menu, slot: .single)
        addTestItem(to: menu, slot: .double)
        addTestItem(to: menu, slot: .triple)
        menu.addItem(.separator())
        let accessibility = NSMenuItem(title: "Allow Accessibility…", action: #selector(openAccessibility), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit TapTap", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func addTestItem(to menu: NSMenu, slot: GestureSlot) {
        let item = NSMenuItem(title: "Test \(slot.title) → \(store[slot].label)", action: #selector(testAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = slot.rawValue
        menu.addItem(item)
    }

    @objc private func testAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let slot = GestureSlot(rawValue: raw) else { return }
        engine.test(slot)
    }

    @objc private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(store: store, settings: detectorSettings, onRecord: { [weak self] slot in self?.recordKey(for: slot) }, onClose: { [weak self] in self?.settingsWindow?.close() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "TapTap Settings"
            window.contentView = NSHostingView(rootView: view)
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func recordKey(for slot: GestureSlot) {
        guard keyMonitor == nil else { return }
        statusMenuItem.title = "Press a key for \(slot.title.lowercased())…"
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            if keyCode == 53 {
                self.stopRecording()
                return nil
            }
            let current = self.store[slot]
            self.emitter.releaseAll()
            self.store[slot] = KeyBinding(keyCode: keyCode, label: self.label(for: event), toggle: current.toggle)
            self.refreshMenu()
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        statusMenuItem.title = "Sensor active"
    }

    private func label(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 58: return "Option"
        case 55: return "Command"
        case 59: return "Control"
        case 56: return "Shift"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        default: return event.charactersIgnoringModifiers?.isEmpty == false ? event.charactersIgnoringModifiers! : "Keycode \(event.keyCode)"
        }
    }

    private func refreshMenu() {
        guard let menu = statusItem.menu else { return }
        for item in menu.items where item.representedObject is String {
            guard let raw = item.representedObject as? String, let slot = GestureSlot(rawValue: raw) else { continue }
            item.title = "Test \(slot.title) → \(store[slot].label)"
        }
    }

    @objc private func quit() {
        emitter.releaseAll()
        engine.stop()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) == settingsWindow else { return }
        stopRecording()
        settingsWindow = nil
    }
}

struct SettingsView: View {
    @ObservedObject var store: BindingStore
    @ObservedObject var settings: DetectorSettings
    let onRecord: (GestureSlot) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gesture signals").font(.title2.bold())
            Text("Choose any keyboard key. Pulse sends a normal key press. Hold keeps the key down until the same gesture is detected again.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(GestureSlot.allCases) { slot in
                HStack {
                    Text(slot.title).frame(width: 100, alignment: .leading)
                    Text(store[slot].label).frame(width: 90, alignment: .leading)
                    Button("Choose key…") { onRecord(slot) }
                    Toggle("Hold / unhold", isOn: Binding(get: { store[slot].toggle }, set: { store[slot].toggle = $0 }))
                }
            }
            Divider()
            Text("Tap detection").font(.headline)
            settingSlider("Sensitivity", value: $settings.sensitivity, range: 0.02...0.30, format: "%.2f g")
            settingSlider("Tap separation", value: $settings.debounceMilliseconds, range: 60...300, format: "%.0f ms")
            settingSlider("Gesture window", value: $settings.gestureWindowMilliseconds, range: 200...900, format: "%.0f ms")
            Spacer()
            HStack {
                Spacer()
                Button("Done", action: onClose)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 500)
    }

    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue)).frame(width: 60, alignment: .trailing)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
