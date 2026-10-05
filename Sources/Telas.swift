import SwiftUI
import ScreenCaptureKit

// Telas splits each external monitor into two independent "screens":
// it creates one virtual display per half, shows each one in a borderless window over the
// physical half, and routes the mouse so movement follows what you see.
// Emergency: ⌃⌥⌘J undoes everything.

/// UI language follows the Mac: Portuguese if it is the preferred language, English otherwise.
private let isPortuguese = Locale.preferredLanguages.first?.hasPrefix("pt") ?? false
func L(_ en: String, _ pt: String) -> String { isPortuguese ? pt : en }

@main
struct TelasApp: App {
    @StateObject private var split = Splitter()

    var body: some Scene {
        MenuBarExtra {
            Text(split.status)
            if let e = split.error { Text("⚠️ \(e)") }
            Divider()
            Section(L("Screens to split", "Telas a dividir")) {
                ForEach(split.externals, id: \.id) { d in
                    Toggle(d.name, isOn: Binding(get: { split.selected.contains(d.id) },
                                                 set: { split.setSelected(d.id, $0) }))
                        .disabled(split.busy)
                }
            }
            Button(split.active ? L("Join screens (⌃⌥⌘J)", "Juntar telas (⌃⌥⌘J)") : L("Split screens", "Dividir telas")) { split.toggle() }
                .disabled(split.busy || (!split.active && split.selected.isEmpty))
            Button(L("Identify screens", "Identificar telas")) { split.identify() }
                .disabled(!split.active)
            Divider()
            Button(L("Quit", "Sair")) { split.stop(); NSApp.terminate(nil) }
        } label: {
            Image(systemName: split.active ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
        }
    }
}

/// One half: a virtual display plus the window that shows it over the physical region.
final class Half: NSObject, SCStreamOutput {
    let physicalID: CGDirectDisplayID
    let fraction: CGRect          // portion of the physical display (0...1)
    let display: CGVirtualDisplay
    let pixelSize: CGSize
    let refreshRate: Double
    var window: NSWindow?
    var stream: SCStream?
    private let layer = CALayer()
    private let cursorLayer = CALayer()

    var virtualID: CGDirectDisplayID { display.displayID }
    var virtualBounds: CGRect { CGDisplayBounds(virtualID) }
    /// Current physical region in global CG coordinates (y down). Always recomputed.
    var physical: CGRect {
        let b = CGDisplayBounds(physicalID)
        return CGRect(x: b.minX + fraction.minX * b.width, y: b.minY + fraction.minY * b.height,
                      width: fraction.width * b.width, height: fraction.height * b.height).integral
    }

    init(physicalID: CGDirectDisplayID, fraction: CGRect, name: String) {
        self.physicalID = physicalID
        self.fraction = fraction
        let b = CGDisplayBounds(physicalID)
        let mm = CGDisplayScreenSize(physicalID)
        pixelSize = CGSize(width: (fraction.width * b.width).rounded(), height: (fraction.height * b.height).rounded())
        let hz = CGDisplayCopyDisplayMode(physicalID)?.refreshRate ?? 0
        refreshRate = hz > 0 ? hz : 60

        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = name
        desc.maxPixelsWide = UInt32(pixelSize.width)
        desc.maxPixelsHigh = UInt32(pixelSize.height)
        desc.sizeInMillimeters = CGSize(width: mm.width * fraction.width, height: mm.height * fraction.height)
        // macOS remembers each display's resolution by vendor/product/serial. A stable identity per
        // physical monitor + half (and the size in the product ID) keeps one half from inheriting
        // another one's resolution.
        desc.vendorID = Splitter.vendorID
        desc.productID = (UInt32(pixelSize.width) &* 31 &+ UInt32(pixelSize.height)) & 0xFFFF
        desc.serialNum = stableID("\(CGDisplayVendorNumber(physicalID))-\(CGDisplayModelNumber(physicalID))-\(CGDisplaySerialNumber(physicalID))-\(fraction.minX)-\(fraction.minY)")
        desc.terminationHandler = { _, _ in }
        display = CGVirtualDisplay(descriptor: desc)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(pixelSize.width), height: UInt32(pixelSize.height), refreshRate: refreshRate)]
        if !display.applySettings(settings) {   // high refresh rate rejected: fall back to 60 Hz
            settings.modes = [CGVirtualDisplayMode(width: UInt32(pixelSize.width), height: UInt32(pixelSize.height), refreshRate: 60)]
            display.applySettings(settings)
        }
        super.init()
    }

    /// Forces the virtual display into its exact native size (ignores any resolution macOS remembered).
    func forceNativeMode() {
        guard let modes = CGDisplayCopyAllDisplayModes(virtualID, nil) as? [CGDisplayMode],
              let mode = modes.first(where: { $0.pixelWidth == Int(pixelSize.width) && $0.pixelHeight == Int(pixelSize.height)
                                              && $0.width == Int(pixelSize.width) }) else { return }
        if CGDisplayCopyDisplayMode(virtualID)?.width == mode.width { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        CGConfigureDisplayWithDisplayMode(cfg, virtualID, mode, nil)
        CGCompleteDisplayConfiguration(cfg, .forSession)
    }

    /// Creates/repositions the window over the physical half (above that screen's menu bar).
    func placeWindow() {
        let frame = cocoaRect(physical)
        if window == nil {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.ignoresMouseEvents = true
            w.isOpaque = true
            w.hasShadow = false
            w.backgroundColor = .black
            w.sharingType = .none
            w.isReleasedWhenClosed = false
            layer.contentsGravity = .resize
            layer.backgroundColor = NSColor.black.cgColor
            w.contentView?.wantsLayer = true
            w.contentView?.layer = layer
            cursorLayer.isHidden = true
            cursorLayer.zPosition = 10
            layer.addSublayer(cursorLayer)
            window = w
        }
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()
    }

    func startCapture() async throws {
        // A freshly created display takes a moment to show up in ScreenCaptureKit
        var scDisplay: SCDisplay?
        for _ in 0..<30 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            scDisplay = content.displays.first { $0.displayID == virtualID }
            if scDisplay != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let scDisplay else { throw TelasError(L("Virtual display did not appear", "O monitor virtual nao apareceu")) }

        let cfg = SCStreamConfiguration()
        cfg.width = Int(pixelSize.width)
        cfg.height = Int(pixelSize.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(refreshRate.rounded()))
        cfg.showsCursor = false   // the cursor is drawn on top in real time (MouseRouter)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 5
        let s = SCStream(filter: SCContentFilter(display: scDisplay, excludingWindows: []), configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "telas.\(virtualID)"))
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = buffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { self.layer.contents = surface }
    }

    /// Draws the cursor at v (global coordinates on the virtual display), or hides it when nil.
    func showCursor(at v: CGPoint?, image: CGImage?, size: CGSize, hotSpot: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let v, let image, virtualBounds.contains(v) {
            let vb = virtualBounds
            let sx = layer.bounds.width / vb.width, sy = layer.bounds.height / vb.height
            let x = (v.x - vb.minX) * sx - hotSpot.x
            let y = layer.bounds.height - (v.y - vb.minY) * sy - (size.height - hotSpot.y)   // layer origin is bottom-left
            cursorLayer.contents = image
            cursorLayer.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            cursorLayer.isHidden = false
        } else {
            cursorLayer.isHidden = true
        }
        CATransaction.commit()
    }

    func teardown() {
        stream?.stopCapture { _ in }
        window?.orderOut(nil)
    }
}

struct TelasError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
final class Splitter: ObservableObject {
    /// Vendor ID that marks the virtual displays created by Telas.
    nonisolated static let vendorID: UInt32 = 0xEEEE

    @Published var active = false
    @Published var busy = false
    @Published var error: String?
    @Published var status = L("Joined", "Juntas")
    /// External displays (ID and name). By default only landscape ones are selected.
    let externals: [(id: CGDirectDisplayID, name: String)] = Splitter.physicalDisplays()
        .filter { CGDisplayIsBuiltin($0) == 0 }
        .map { id in
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName ?? "Display \(id)"
            let b = CGDisplayBounds(id)
            return (id, "\(name) (\(b.width >= b.height ? L("landscape", "horizontal") : L("portrait", "vertical")))")
        }
    @Published var selected: Set<CGDirectDisplayID> = Set(Splitter.physicalDisplays().filter {
        CGDisplayIsBuiltin($0) == 0 && CGDisplayBounds($0).width > CGDisplayBounds($0).height
    })

    private var halves: [Half] = []
    private var router: MouseRouter?
    private var screenObserver: NSObjectProtocol?
    private var originalOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var nextName = 1

    func toggle() { active ? stop() : start() }

    /// Selects/deselects a display; while split is on, splits or joins only that display.
    func setSelected(_ id: CGDirectDisplayID, _ on: Bool) {
        if on { selected.insert(id) } else { selected.remove(id) }
        guard active else { return }
        if on { run { try await self.add([id]) } } else { run { try await self.remove(id) } }
    }

    func start() {
        error = nil
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            error = L("Screen Recording permission missing: allow Telas in System Settings > Privacy & Security, then quit and reopen the app",
                      "Sem permissao de Gravacao de Tela: libere o Telas em Ajustes > Privacidade e Seguranca, saia e abra o app de novo")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            return
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            error = L("Accessibility permission missing: allow Telas in System Settings > Privacy & Security",
                      "Sem permissao de Acessibilidade: libere o Telas em Ajustes > Privacidade e Seguranca")
            return
        }
        // Original position of the physical displays: macOS pushes them around when virtual ones appear
        originalOrigins = Dictionary(uniqueKeysWithValues: Self.physicalDisplays().map { ($0, CGDisplayBounds($0).origin) })
        active = true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.halves.forEach { $0.placeWindow() } }
        }
        let ids = Self.physicalDisplays().filter { CGDisplayIsBuiltin($0) == 0 && selected.contains($0) }
        run { try await self.add(ids) }
    }

    /// Runs one change at a time, showing progress and undoing everything on failure.
    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        status = L("Adjusting…", "Ajustando…")
        Task {
            do { try await work() } catch { self.stop(); self.error = error.localizedDescription }
            busy = false
            if active { status = L("Split: \(halves.count) halves", "Dividido: \(halves.count) metades") }
        }
    }

    /// Splits the given displays: landscape -> left/right, portrait -> top/bottom.
    private func add(_ ids: [CGDirectDisplayID]) async throws {
        var added: [Half] = []
        for id in ids where !halves.contains(where: { $0.physicalID == id }) {
            let b = CGDisplayBounds(id)
            let parts = b.width >= b.height
                ? [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
                : [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
            for f in parts {
                added.append(Half(physicalID: id, fraction: f, name: "Telas \(nextName)"))
                nextName += 1
            }
        }
        guard !added.isEmpty else { return }
        halves += added
        try await Task.sleep(for: .milliseconds(1500))   // let macOS finish rearranging
        added.forEach { $0.forceNativeMode() }
        restoreArrangement(originalOrigins)
        try await Task.sleep(for: .milliseconds(1000))
        for h in added { try await h.startCapture() }
        halves.forEach { $0.placeWindow() }
        WindowMover.move(added.map { ($0.physical, $0.virtualBounds) })   // windows: physical display -> halves
        try restartRouter()
        identify()
    }

    /// Joins one display: brings its windows back, removes its halves and keeps the others.
    private func remove(_ id: CGDirectDisplayID) async throws {
        let gone = halves.filter { $0.physicalID == id }
        guard !gone.isEmpty else { return }
        WindowMover.move(gone.map { ($0.virtualBounds, $0.physical) })   // windows: halves -> physical display
        gone.forEach { $0.teardown() }
        halves.removeAll { $0.physicalID == id }
        if halves.isEmpty { stop(); return }
        try await Task.sleep(for: .milliseconds(1500))
        restoreArrangement(originalOrigins)
        try await Task.sleep(for: .milliseconds(500))
        halves.forEach { $0.placeWindow() }
        try restartRouter()
    }

    private func restartRouter() throws {
        router?.stop()
        let r = MouseRouter(halves: halves, onPanic: { [weak self] in Task { @MainActor in self?.stop() } })
        guard r.start() else { throw TelasError(L("Could not take control of the mouse", "Nao consegui controlar o mouse")) }
        router = r
    }

    /// Shows a big number on each half for 3 s.
    func identify() {
        var labels: [NSWindow] = []
        for (i, h) in halves.enumerated() {
            let b = cocoaRect(h.virtualBounds)
            let size = CGSize(width: 320, height: 320)
            let w = NSWindow(contentRect: CGRect(x: b.midX - size.width / 2, y: b.midY - size.height / 2, width: size.width, height: size.height),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = NSColor.black.withAlphaComponent(0.7)
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            let t = NSTextField(labelWithString: "\(i + 1)")
            t.font = .systemFont(ofSize: 220, weight: .bold)
            t.textColor = .white
            t.alignment = .center
            t.frame = CGRect(x: 0, y: 30, width: size.width, height: 260)
            w.contentView?.addSubview(t)
            w.orderFrontRegardless()
            labels.append(w)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { labels.forEach { $0.orderOut(nil) } }
    }

    /// Physical displays back where they were. Virtual ones are parked to the right as a translated
    /// copy of the physical layout (a portrait monitor's halves stacked, a landscape one's side by
    /// side), so dragging windows between halves follows what you see.
    private func restoreArrangement(_ origins: [CGDirectDisplayID: CGPoint]) {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        for (id, o) in origins { CGConfigureDisplayOrigin(cfg, id, Int32(o.x), Int32(o.y)) }
        // Where each half sits on the restored physical layout
        let rects = halves.map { h -> CGRect in
            let size = CGDisplayBounds(h.physicalID).size
            let o = origins[h.physicalID] ?? CGDisplayBounds(h.physicalID).origin
            return CGRect(x: o.x + h.fraction.minX * size.width, y: o.y + h.fraction.minY * size.height,
                          width: h.pixelSize.width, height: h.pixelSize.height)
        }
        let rightEdge = origins.map { CGRect(origin: $0.value, size: CGDisplayBounds($0.key).size).maxX }.max() ?? 0
        let dx = rightEdge - (rects.map(\.minX).min() ?? 0)
        for (h, r) in zip(halves, rects) {
            CGConfigureDisplayOrigin(cfg, h.virtualID, Int32(r.minX + dx), Int32(r.minY))
        }
        CGCompleteDisplayConfiguration(cfg, .forSession)
    }

    func stop() {
        router?.stop()
        router = nil
        if !halves.isEmpty { WindowMover.move(halves.map { ($0.virtualBounds, $0.physical) }) }   // halves -> physical
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        halves.forEach { $0.teardown() }
        halves.removeAll()   // releasing the CGVirtualDisplay removes the virtual display
        active = false
        status = L("Joined", "Juntas")
    }

    /// Active physical displays (excludes virtual displays created by Telas).
    nonisolated static func physicalDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).filter { CGDisplayVendorNumber($0) != vendorID }
    }
}

/// Keeps a "logical" cursor in physical space (what you see) and puts the real cursor on the
/// matching virtual display while it is over a half.
final class MouseRouter {
    let halves: [Half]
    let onPanic: () -> Void
    var logical: CGPoint
    var tap: CFMachPort?
    /// Events to ignore after a warp: macOS adds the jump to the next event's delta.
    private var skip = 0
    private var cursorImage: (image: CGImage?, size: CGSize, hotSpot: CGPoint, at: Date) = (nil, .zero, .zero, .distantPast)

    init(halves: [Half], onPanic: @escaping () -> Void) {
        self.halves = halves
        self.onPanic = onPanic
        let now = CGEvent(source: nil)?.location ?? .zero
        logical = now
        // If the cursor is on a virtual display, map it back to the visible place
        if let h = halves.first(where: { $0.virtualBounds.contains(now) }) {
            logical = Self.map(now, from: h.virtualBounds, to: h.physical)
        } else if !Self.physicalRects().contains(where: { $0.contains(now) }) {
            logical = CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX, y: CGDisplayBounds(CGMainDisplayID()).midY)
        }
    }

    static func physicalRects() -> [CGRect] { Splitter.physicalDisplays().map { CGDisplayBounds($0) } }

    func start() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, ctx in
            let r = Unmanaged<MouseRouter>.fromOpaque(ctx!).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let t = r.tap { CGEvent.tapEnable(tap: t, enable: true) }
            case .keyDown:
                // ⌃⌥⌘J: emergency, undo everything
                let f = event.flags
                if event.getIntegerValueField(.keyboardEventKeycode) == 38,
                   f.contains(.maskControl), f.contains(.maskAlternate), f.contains(.maskCommand) {
                    r.onPanic()
                    return nil
                }
            default:
                r.route(event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me)
        guard let tap else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Without this macOS freezes the mouse for ~0.25 s after every warp
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        warp(target(for: logical))
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        for h in halves { h.showCursor(at: nil, image: nil, size: .zero, hotSpot: .zero) }
        warp(logical)   // put the cursor back where it is visible
    }

    /// Draws the cursor on the half where the real cursor is (shape refreshed every 30 ms).
    private func drawCursor(_ v: CGPoint) {
        if Date().timeIntervalSince(cursorImage.at) > 0.03 {
            let c = NSCursor.currentSystem ?? NSCursor.arrow
            var r = CGRect(origin: .zero, size: c.image.size)
            cursorImage = (c.image.cgImage(forProposedRect: &r, context: nil, hints: nil), c.image.size, c.hotSpot, Date())
        }
        for h in halves { h.showCursor(at: v, image: cursorImage.image, size: cursorImage.size, hotSpot: cursorImage.hotSpot) }
    }

    /// Inside one region macOS moves the cursor by itself (native speed). Telas only warps when
    /// crossing: half <-> half, half <-> physical display, or to stop the cursor from entering a
    /// virtual display through the "back door" of the display arrangement.
    private func route(_ event: CGEvent) {
        let p = event.location
        let d = CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX), y: event.getDoubleValueField(.mouseEventDeltaY))
        if skip > 0 { skip -= 1; drawCursor(p); return }

        let next = CGPoint(x: p.x + d.x, y: p.y + d.y)
        var warped = false
        defer { drawCursor(warped ? event.location : next) }
        let rects = Self.physicalRects()
        let free = { (q: CGPoint) in rects.contains { $0.contains(q) } && !self.halves.contains { $0.physical.contains(q) } }
        let wanted: CGPoint   // where the cursor wants to go, in physical space (what you see)

        if let h = halves.first(where: { $0.virtualBounds.contains(p) }) {
            if h.virtualBounds.contains(next) { logical = Self.map(next, from: h.virtualBounds, to: h.physical); return }
            wanted = Self.map(next, from: h.virtualBounds, to: h.physical)
        } else if free(p) {
            if free(next) { logical = next; return }
            wanted = next
        } else {
            wanted = CGPoint(x: logical.x + d.x, y: logical.y + d.y)   // unexpected place: follow the logical cursor
        }

        let t: CGPoint
        if let h = halves.first(where: { $0.physical.contains(wanted) }) {
            t = Self.map(wanted, from: h.physical, to: h.virtualBounds); logical = wanted
        } else if free(wanted) {
            t = wanted; logical = wanted
        } else {
            t = target(for: logical)   // outside every display: stay put
        }
        event.location = t
        warp(t)
        warped = true
        skip = 1
    }

    private func target(for p: CGPoint) -> CGPoint {
        guard let h = halves.first(where: { $0.physical.contains(p) }) else { return p }
        return Self.map(p, from: h.physical, to: h.virtualBounds)
    }

    static func map(_ p: CGPoint, from a: CGRect, to b: CGRect) -> CGPoint {
        CGPoint(x: b.minX + (p.x - a.minX) * b.width / a.width,
                y: b.minY + (p.y - a.minY) * b.height / a.height)
    }

    private func warp(_ p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// Moves other apps' windows between regions (via Accessibility), by each window's center.
enum WindowMover {
    static func move(_ pairs: [(from: CGRect, to: CGRect)]) {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for w in windows {
                guard var frame = frame(of: w), !isFullScreen(w),
                      let pair = pairs.first(where: { $0.from.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { continue }
                // Same relative position; shrink if it does not fit
                frame.size.width = min(frame.width, pair.to.width)
                frame.size.height = min(frame.height, pair.to.height)
                var o = CGPoint(x: pair.to.minX + (frame.minX - pair.from.minX) * pair.to.width / pair.from.width,
                                y: pair.to.minY + (frame.minY - pair.from.minY) * pair.to.height / pair.from.height)
                o.x = max(pair.to.minX, min(o.x, pair.to.maxX - frame.width))
                o.y = max(pair.to.minY, min(o.y, pair.to.maxY - frame.height))
                var size = frame.size
                if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
                if let v = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
            }
        }
    }

    private static func frame(of w: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func isFullScreen(_ w: AXUIElement) -> Bool {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &v)
        return (v as? Bool) ?? false
    }
}

/// Stable 32-bit FNV-1a hash (used as the virtual display serial number).
func stableID(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
    return h
}

/// Converts a rect in global CG coordinates (origin at the top of the main display) to Cocoa (origin at the bottom).
func cocoaRect(_ r: CGRect) -> CGRect {
    let mainH = CGDisplayBounds(CGMainDisplayID()).height
    return CGRect(x: r.minX, y: mainH - r.maxY, width: r.width, height: r.height)
}
