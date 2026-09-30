import Cocoa
import ApplicationServices
import Carbon
import CoreAudio

private final class ToolbarButton: NSButton {
    var invoke: () -> Void = {}
    convenience init(_ title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title; invoke = action; target = self; self.action = #selector(run)
        bezelStyle = .inline; font = .systemFont(ofSize: 13)
    }
    @objc private func run() { invoke() }
}

private final class ToolbarClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private final class ToolbarRows: NSStackView {
    override var isFlipped: Bool { true }
}

private final class ToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ToolbarBackground: NSView {
    var lowerEdge: [CGFloat] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard lowerEdge.count > 1 else { return }
        let step = bounds.width / CGFloat(lowerEdge.count - 1)
        let path = NSBezierPath()
        path.move(to: .zero); path.line(to: CGPoint(x: bounds.width, y: 0))
        for i in lowerEdge.indices.reversed() { path.line(to: CGPoint(x: CGFloat(i) * step, y: lowerEdge[i])) }
        path.close(); NSColor.black.setFill(); path.fill()
    }
}

private struct AppMenuEntry {
    let element: AXUIElement
    let title: String
    let enabled: Bool
    let submenu: AXUIElement?
}

/// Standard CoreAudio volume. Devices without a writable master control keep the Settings fallback.
private enum ToolbarAudio {
    static func device() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }
    static func volume() -> (AudioDeviceID, Float32, Bool)? {
        guard let id = device() else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size), writable = DarwinBoolean(false)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        let canWrite = AudioObjectIsPropertySettable(id, &address, &writable) == noErr && writable.boolValue
        return (id, value, canWrite)
    }
    static func set(_ value: Float32, device id: AudioDeviceID) -> Bool {
        guard device() == id else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value = min(1, max(0, value))
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }
}

/// Real AppKit controls and AX commands. No screen capture, pixel slicing, or synthesized mouse input.
final class FloatingMenuController: NSObject, NSWindowDelegate {
    private var background: NSPanel?
    private let backgroundView = ToolbarBackground()
    private var tiles: [NSPanel] = []
    private var popover: NSPanel?
    private var rows: NSStackView?
    private var target: NSRunningApplication?
    private var roots: [AppMenuEntry] = []
    private var stack: [(AXUIElement, String)] = []
    private let worker = DispatchQueue(label: "local.deadzone.native-menu")
    private var generation = 0
    private var active = false, suspended = false, hidden = false
    private var screen: NSScreen?
    private var screenFrame = CGRect.zero, safeFrame = CGRect.zero
    private var dead: [CGRect] = []
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var clockButton: NSButton?
    private var audioDevice: AudioDeviceID?
    private var audioLabel: NSTextField?
    var zones: () -> [DeadZone] = { [] }
    var openSettings: () -> Void = {}
    var isInteracting: Bool { popover?.isVisible == true }

    func start() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != getpid() { target = front }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            self.target = app
            self.closePopover()
            if self.isVisible { self.readRoots() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.clockButton?.title = Self.clockText()
        }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            Unmanaged<FloatingMenuController>.fromOpaque(pointer).takeUnretainedValue().toggle()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x445A4D4E, id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)
    }
    deinit {
        timer?.invalidate()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
    private var isVisible: Bool { background?.isVisible == true }
    func configure(enabled: Bool, suspended: Bool) {
        if enabled && !active { hidden = false }
        active = enabled; self.suspended = suspended
        guard enabled, !suspended, !hidden else { conceal(); return }
        show()
    }
    func toggle() {
        guard !suspended else { return }
        if isVisible { hidden = true; conceal() } else { hidden = false; show() }
    }
    private func conceal() {
        generation += 1; closePopover(); background?.orderOut(nil)
        tiles.forEach { $0.orderOut(nil) }; tiles.removeAll(); clockButton = nil
    }
    private func show() {
        let all = zones()
        let candidates = NSScreen.screens.sorted { a, b in
            all.contains { $0.screen.uuid == a.uuid } && !all.contains { $0.screen.uuid == b.uuid }
        }
        screen = nil
        for s in candidates {
            let obstacles = all.filter { $0.screen.uuid == s.uuid }.flatMap(\.rects)
            if let free = WindowAvoider().maxRect(dead: obstacles, screen: toCG(s.visibleFrame)), free.width >= 360, free.height >= 240 {
                screen = s; screenFrame = toCG(s.visibleFrame); safeFrame = free; dead = obstacles; break
            }
        }
        guard screen != nil else { conceal(); return }
        if background == nil {
            let p = ToolbarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = L("曲线工具栏背景", "Curved Toolbar Background")
            p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false; p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false; p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = backgroundView; p.setAccessibilityElement(false); background = p
        }
        background?.setFrame(toNS(screenFrame), display: true)
        background?.orderFrontRegardless()
        buildTiles(); readRoots()
    }
    private static func clockText() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"; return formatter.string(from: Date())
    }
    private func tile(_ title: String, x: CGFloat, width: CGFloat, action: @escaping () -> Void) -> NSButton? {
        guard let frame = ContourMenuLayout.itemFrame(range: x...(x + width), screen: screenFrame, dead: dead, height: 30) else { return nil }
        let button = ToolbarButton(title, action: action)
        button.contentTintColor = .white
        button.frame = NSRect(origin: .zero, size: frame.size)
        button.autoresizingMask = [.width, .height]
        let p = ToolbarPanel(contentRect: toNS(frame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = title; p.backgroundColor = .black; p.hasShadow = false; p.hidesOnDeactivate = false; p.level = .floating
        p.appearance = NSAppearance(named: .darkAqua)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.contentView = button
        p.orderFrontRegardless(); tiles.append(p); return button
    }
    private func buildTiles() {
        tiles.forEach { $0.orderOut(nil) }; tiles.removeAll()
        let rightStart = screenFrame.maxX - 366
        var x = screenFrame.minX + 8
        for (index, entry) in roots.enumerated() {
            let width = min(150, max(42, (entry.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 22))
            if x + width > rightStart - 65 {
                _ = tile(L("更多…", "More…"), x: x, width: 62) { [weak self] in self?.showRootList() }; break
            }
            _ = tile(entry.title, x: x, width: width) { [weak self] in self?.chooseRoot(index) }
            x += width + 2
        }
        if roots.isEmpty {
            _ = tile(target?.localizedName ?? L("应用菜单", "App menus"), x: x, width: min(170, max(90, rightStart - x - 8))) { [weak self] in self?.showRootList() }
        }
        _ = tile(L("应用", "Apps"), x: rightStart, width: 56) { [weak self] in self?.showApps() }
        _ = tile(L("声音", "Sound"), x: rightStart + 60, width: 56) { [weak self] in self?.showSound() }
        clockButton = tile(Self.clockText(), x: rightStart + 120, width: 120) { [weak self] in self?.showDate() }
        _ = tile("DeadZone", x: rightStart + 244, width: 106) { [weak self] in self?.showToolbarMenu() }
        let count = max(2, Int(screenFrame.width / 2)), frames = tiles.map { toCG($0.frame) }
        backgroundView.lowerEdge = (0...count).map { i in
            let x = screenFrame.minX + CGFloat(i) * screenFrame.width / CGFloat(count)
            let y = ContourMenuLayout.edge(x0: x - 2, x1: x + 2, screen: screenFrame, dead: dead)
            let tileBottom = frames.filter { $0.minX - 2 <= x && $0.maxX + 2 >= x }.map(\.maxY).max() ?? y
            return min(max(y + 30, tileBottom), screenFrame.maxY) - screenFrame.minY
        }
        backgroundView.needsDisplay = true
    }
    private func prepare(_ title: String) {
        generation += 1
        if screen == nil { show() }
        guard screen != nil else { return }
        if popover == nil {
            let p = ToolbarPanel(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false; p.level = .floating
            p.appearance = NSAppearance(named: .darkAqua); p.delegate = self
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; popover = p
        }
        guard let p = popover else { return }
        p.title = L("曲线工具栏 · ", "Curved Toolbar · ") + title
        let w = min(440, safeFrame.width - 12), h = min(480, safeFrame.height - 12)
        p.setFrame(toNS(CGRect(x: safeFrame.maxX - w - 6, y: safeFrame.minY + 6, width: w, height: h)), display: true)
        let scroll = NSScrollView(frame: p.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.contentView = ToolbarClipView(frame: scroll.bounds)
        let list = ToolbarRows()
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 6
        list.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        p.contentView = scroll; rows = list
        p.makeKeyAndOrderFront(nil)
    }
    private func text(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13); label.translatesAutoresizingMaskIntoConstraints = false
        rows?.addArrangedSubview(label)
        if let rows { label.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -24).isActive = true }
    }
    private func row(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        let button = ToolbarButton(title, action: action)
        button.alignment = .left; button.isEnabled = enabled; button.translatesAutoresizingMaskIntoConstraints = false
        rows?.addArrangedSubview(button)
        if let rows { button.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -24).isActive = true }
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    }
    private func closePopover() { generation += 1; popover?.orderOut(nil); rows = nil; stack = [] }
    func windowWillClose(_ notification: Notification) { closePopover() }
    private func showToolbarMenu() {
        prepare("DeadZone")
        row(L("打开 DeadZone 设置", "Open DeadZone Settings")) { [weak self] in self?.closePopover(); self?.openSettings() }
        row(L("刷新应用菜单", "Refresh App Menus")) { [weak self] in self?.closePopover(); self?.readRoots() }
        row(L("隐藏工具栏 · ⌃⌥M 再次显示", "Hide Toolbar · ⌃⌥M to show")) { [weak self] in self?.hidden = true; self?.conceal() }
        text(L("独立原生工具栏。第三方状态图标尚未接管。", "Independent native toolbar. Third-party status icons are not yet integrated."))
    }
    private func showApps() {
        prepare(L("应用", "Apps"))
        for app in NSWorkspace.shared.runningApplications.filter({ $0.activationPolicy == .regular && $0.processIdentifier != getpid() }).sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
            row(app.localizedName ?? "App") { [weak self] in self?.closePopover(); app.activate(options: [.activateIgnoringOtherApps]) }
        }
        row(L("打开应用程序文件夹", "Open Applications")) { [weak self] in self?.closePopover(); NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
    }
    private func showDate() {
        prepare(L("日期与时间", "Date & Time"))
        let formatter = DateFormatter(); formatter.dateStyle = .full; formatter.timeStyle = .short
        text(formatter.string(from: Date()))
        row(L("打开日历", "Open Calendar")) { [weak self] in
            self?.closePopover()
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        }
    }
    func showSound() {
        prepare(L("声音", "Sound"))
        if let (device, value, writable) = ToolbarAudio.volume() {
            audioDevice = device
            let label = NSTextField(labelWithString: L("输出音量：", "Output volume: ") + "\(Int(value * 100))%")
            rows?.addArrangedSubview(label); audioLabel = label
            let slider = NSSlider(value: Double(value), minValue: 0, maxValue: 1, target: self, action: #selector(changeVolume(_:)))
            slider.isContinuous = true; slider.isEnabled = writable; slider.setAccessibilityLabel(L("输出音量", "Output volume"))
            slider.translatesAutoresizingMaskIntoConstraints = false; rows?.addArrangedSubview(slider)
            if let rows { slider.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -24).isActive = true }
            if !writable { text(L("当前设备不允许软件调节主音量。", "This device does not allow software master-volume adjustment.")) }
        } else {
            text(L("当前音频设备未提供主音量控制，可在声音设置中选择输出设备。", "The audio device has no master-volume control. Choose an output in Sound Settings."))
        }
        row(L("打开系统声音设置", "Open System Sound Settings")) { [weak self] in
            self?.closePopover(); NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
        }
        row(L("刷新设备状态", "Refresh Device")) { [weak self] in self?.showSound() }
    }
    @objc private func changeVolume(_ sender: NSSlider) {
        guard let device = audioDevice else { return }
        if ToolbarAudio.set(sender.floatValue, device: device) { audioLabel?.stringValue = L("输出音量：", "Output volume: ") + "\(Int(sender.doubleValue * 100))%" }
        else { sender.isEnabled = false; audioLabel?.stringValue = L("设备已变化，请刷新后重试。", "Device changed. Refresh and retry.") }
    }
    private static func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func entries(_ container: AXUIElement) -> [AppMenuEntry] {
        let children = attr(container, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let deadline = Date().addingTimeInterval(3)
        var result: [AppMenuEntry] = []
        for item in children.prefix(200) {
            if Date() > deadline { break }
            guard let title = attr(item, kAXTitleAttribute) as? String, !title.isEmpty else { continue }
            let submenu = (attr(item, kAXChildrenAttribute) as? [AXUIElement])?.first { attr($0, kAXRoleAttribute) as? String == kAXMenuRole }
            let mark = attr(item, kAXMenuItemMarkCharAttribute) as? String ?? ""
            result.append(AppMenuEntry(element: item, title: (mark.isEmpty ? "" : mark + " ") + title,
                                       enabled: attr(item, kAXEnabledAttribute) as? Bool ?? true, submenu: submenu))
        }
        return result
    }
    private func readRoots() {
        generation += 1; let token = generation
        roots = []; buildTiles()
        guard AXIsProcessTrusted(), let target, !target.isTerminated else { return }
        let app = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        worker.async { [weak self] in
            var result: [AppMenuEntry] = []
            if let raw = Self.attr(app, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
                result = Self.entries(raw as! AXUIElement)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.isVisible else { return }
                self.roots = result; self.buildTiles()
            }
        }
    }
    private func showRootList() {
        prepare(target?.localizedName ?? L("应用菜单", "App menus"))
        if roots.isEmpty { text(L("暂无可读取的菜单。先切换到目标应用；若仍为空，请检查辅助功能权限。", "No accessible menus. Switch to the target app and check Accessibility permission.")) }
        for index in roots.indices { row(roots[index].title) { [weak self] in self?.chooseRoot(index) } }
    }
    private func chooseRoot(_ index: Int) {
        guard roots.indices.contains(index) else { return }
        let entry = roots[index]
        stack = []
        choose(entry)
    }
    private func choose(_ entry: AppMenuEntry) {
        guard entry.enabled else { return }
        if let sub = entry.submenu {
            stack.append((sub, entry.title)); loadSubmenu(); return
        }
        guard let app = target, !app.isTerminated else { return }
        let element = entry.element
        closePopover()
        app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            self?.worker.async {
                let enabled = Self.attr(element, kAXEnabledAttribute) as? Bool ?? false
                let result = enabled ? AXUIElementPerformAction(element, kAXPressAction as CFString) : .actionUnsupported
                if result != .success { DispatchQueue.main.async { [weak self] in self?.prepare(L("无法执行", "Cannot Execute")); self?.text(L("这个应用未接受菜单命令，请重新打开菜单后重试。", "The app rejected the command. Reopen the menu and retry.")) } }
            }
        }
    }
    private func loadSubmenu() {
        guard let (element, title) = stack.last else { showRootList(); return }
        prepare(title)
        let token = generation
        text(L("正在读取…", "Loading…"))
        worker.async { [weak self] in
            let entries = Self.entries(element)
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.isInteracting else { return }
                self.rows?.arrangedSubviews.forEach { self.rows?.removeArrangedSubview($0); $0.removeFromSuperview() }
                self.row(L("‹ 返回", "‹ Back")) { [weak self] in
                    guard let self else { return }; if !self.stack.isEmpty { self.stack.removeLast() }; self.loadSubmenu()
                }
                if entries.isEmpty { self.text(L("此动态菜单未提供可读取的内容。", "This dynamic menu exposes no accessible items.")) }
                for entry in entries { self.row(entry.title + (entry.submenu == nil ? "" : "  ›"), enabled: entry.enabled) { [weak self] in self?.choose(entry) } }
            }
        }
    }
}
