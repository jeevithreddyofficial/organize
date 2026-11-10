import Cocoa
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Private APIs (Spaces + AX window id)
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace") func CGSGetActiveSpace(_ cid: Int32) -> Int
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ el: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// True if the currently visible Space is the first desktop (Desktop 1) of the main display.
func isOnDesktopOne() -> Bool {
    let cid = CGSMainConnectionID()
    guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]],
          let first = displays.first,
          let spaces = first["Spaces"] as? [[String: Any]],
          let desktop1 = spaces.first(where: { ($0["type"] as? Int) == 0 }),
          let id = (desktop1["id64"] as? Int) ?? (desktop1["ManagedSpaceID"] as? Int)
    else { return true } // can't tell -> don't block
    return CGSGetActiveSpace(cid) == id
}

// MARK: - Windows
struct Win {
    let el: AXUIElement
    let id: CGWindowID
    var frame: CGRect
}

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? T
}

func frameOf(_ el: AXUIElement) -> CGRect? {
    var pv: CFTypeRef?, sv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

func setFrame(_ el: AXUIElement, _ r: CGRect) {
    var p = r.origin, s = r.size
    func apply() {
        if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv) }
    }
    apply(); apply() // size first-time may be clamped by position; second pass settles it
}

/// Standard, visible, non-minimized, non-fullscreen windows on the current Space.
func currentWindows() -> [Win] {
    var out: [Win] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let wins: [AXUIElement] = attr(ax, kAXWindowsAttribute) else { continue }
        for w in wins {
            let role: String? = attr(w, kAXRoleAttribute)
            let sub: String? = attr(w, kAXSubroleAttribute)
            guard role == kAXWindowRole as String, sub == kAXStandardWindowSubrole as String else { continue }
            if let m: Bool = attr(w, kAXMinimizedAttribute), m { continue }
            if let f: Bool = attr(w, "AXFullScreen"), f { continue }
            guard let fr = frameOf(w), fr.width > 120, fr.height > 80 else { continue }
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(w, &wid)
            out.append(Win(el: w, id: wid, frame: fr))
        }
    }
    return out
}

// MARK: - Grid logic
/// Work area in AX (top-left origin) coordinates.
func workArea() -> CGRect {
    let primary = NSScreen.screens[0]
    let v = (NSScreen.main ?? primary).visibleFrame
    return CGRect(x: v.minX, y: primary.frame.height - v.maxY, width: v.width, height: v.height)
}

/// Target cells for n windows: 2 -> 2x1, 3 -> 2 on top + 1 full-width bottom, 4 -> 2x2, 5+ -> ceil(sqrt) columns.
func cells(_ n: Int, in a: CGRect) -> [CGRect] {
    let cols = n <= 3 ? (n == 1 ? 1 : 2) : Int(ceil(sqrt(Double(n))))
    let rows = n == 3 ? 2 : Int(ceil(Double(n) / Double(cols)))
    var res: [CGRect] = []
    let h = a.height / CGFloat(rows)
    for r in 0..<rows {
        let inRow = (r == rows - 1) ? n - cols * (rows - 1) : cols
        let w = a.width / CGFloat(inRow)
        for c in 0..<inRow {
            res.append(CGRect(x: a.minX + CGFloat(c) * w, y: a.minY + CGFloat(r) * h, width: w, height: h))
        }
    }
    return res
}

func close(_ a: CGRect, _ b: CGRect, tol: CGFloat = 24) -> Bool {
    abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol &&
    abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
}

/// A tiling is "already a grid" if every window sits in a distinct cell of the layout.
/// Windows that can't shrink to a cell (min size) are matched by origin only.
func isGrid(_ wins: [Win], _ area: CGRect) -> Bool {
    var free = cells(wins.count, in: area)
    for w in wins {
        guard let i = free.firstIndex(where: { close(w.frame, $0) }) else { return false }
        free.remove(at: i)
    }
    return true
}

/// Assign windows to cells by reading order so windows keep roughly their relative positions.
func organize(_ wins: [Win], _ area: CGRect) {
    let sorted = wins.sorted { a, b in
        let ra = (a.frame.minY / 150).rounded(), rb = (b.frame.minY / 150).rounded()
        return ra != rb ? ra < rb : a.frame.minX < b.frame.minX
    }
    for (w, c) in zip(sorted, cells(wins.count, in: area)) { setFrame(w.el, c.insetBy(dx: 2, dy: 2)) }
}

// MARK: - Controller
final class Controller: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    var lastSignature = ""
    var pendingSince: Date?
    var timer: Timer?
    let toggleItem = NSMenuItem(title: "Auto-organize all desktops", action: #selector(toggle), keyEquivalent: "")
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Organize")
        let m = NSMenu()
        toggleItem.target = self; toggleItem.state = enabled ? .on : .off
        m.addItem(toggleItem)
        let now = NSMenuItem(title: "Organize Now", action: #selector(organizeNow), keyEquivalent: "o"); now.target = self
        now.keyEquivalentModifierMask = [.control, .option]
        m.addItem(now)
        m.addItem(.separator()); m.addItem(statusLine); m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = m

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { statusLine.title = "Needs Accessibility access (see menu)" }
        let ax = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: ""); ax.target = self
        m.insertItem(ax, at: 3)

        registerHotKey()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.tick() }
    }

    @objc func toggle() {
        enabled.toggle(); toggleItem.state = enabled ? .on : .off
        UserDefaults.standard.set(enabled, forKey: "enabled"); lastSignature = ""
    }

    /// Global hotkey ⌃⌥O (works in any app, needs no extra permission).
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            Unmanaged<Controller>.fromOpaque(ctx!).takeUnretainedValue().organizeNow()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_O), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: 0x4F52474E, id: 1), GetApplicationEventTarget(), 0, &ref)
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func organizeNow() {
        let w = currentWindows()
        if w.count >= 2 { organize(w, workArea()) }
    }

    /// Re-organize only when the set of windows changes (opened/closed/moved to this Space) and has settled.
    func tick() {
        let trusted = AXIsProcessTrusted()
        let wins = trusted ? currentWindows() : []
        if trusted, statusLine.title.hasPrefix("Needs Accessibility") { statusLine.title = "Ready"; lastSignature = "" }
        if !trusted { statusLine.title = "Needs Accessibility access (see menu)" }
        guard trusted, enabled else { return }
        let sig = wins.map { String($0.id) }.sorted().joined(separator: ",")
        if sig != lastSignature {
            if pendingSince == nil { pendingSince = Date(); return }   // wait one more tick so new windows settle
            if Date().timeIntervalSince(pendingSince!) < 0.7 { return }
            pendingSince = nil
            lastSignature = sig
            if wins.count >= 2 && !isGrid(wins, workArea()) {
                organize(wins, workArea())
                statusLine.title = "Organized \(wins.count) windows"
            } else {
                statusLine.title = "\(wins.count) windows – nothing to do"
            }
        } else { pendingSince = nil }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
