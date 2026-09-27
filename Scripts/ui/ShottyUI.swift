import AppKit
import ApplicationServices

// Pointer, menu, window, and Accessibility helpers for verifying Shotty. Run through `shotty-ui`.
// Coordinates are global points with the origin at the top left of the main display.

let bundleID = "local.markus.Shotty"
let args = Array(CommandLine.arguments.dropFirst())
let source = CGEventSource(stateID: .hidSystemState)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
func number(_ index: Int) -> Double {
    guard index < args.count, let value = Double(args[index]) else { fail("missing number at argument \(index + 1)") }
    return value
}
func point(_ index: Int) -> CGPoint { CGPoint(x: number(index), y: number(index + 1)) }
func mouse(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) ?? [] }
func title(_ element: AXUIElement) -> String { attribute(element, kAXTitleAttribute) ?? "" }
func app(_ id: String = bundleID) -> (NSRunningApplication, AXUIElement) {
    guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { fail("\(id) is not running") }
    return (running, AXUIElementCreateApplication(running.processIdentifier))
}
func press(_ element: AXUIElement) { print(AXUIElementPerformAction(element, kAXPressAction as CFString) == .success ? "ok" : "failed") }
func window(named name: String, in id: String = bundleID) -> AXUIElement? {
    (attribute(app(id).1, kAXWindowsAttribute) as [AXUIElement]?)?.first { title($0) == name }
}
let clipMark = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shotty-ui-clip")

switch args.first {
case "move":
    mouse(.mouseMoved, point(1))
case "click":
    let target = point(1)
    mouse(.mouseMoved, target); usleep(50_000)
    mouse(.leftMouseDown, target); usleep(50_000)
    mouse(.leftMouseUp, target)
case "drag":
    // Slow enough for drag and drop receivers: a hold after the press, even steps, a hold before release.
    let from = point(1), to = point(3), steps = args.count > 5 ? Int(number(5)) : 30
    mouse(.mouseMoved, from); usleep(100_000)
    mouse(.leftMouseDown, from); usleep(150_000)
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        usleep(15_000)
    }
    usleep(200_000)
    mouse(.leftMouseUp, to)
case "menu":
    guard args.count > 1 else { fail("usage: menu <menu> [item]") }
    guard let bar: AXUIElement = attribute(app().1, kAXMenuBarAttribute),
          let menu = children(bar).first(where: { title($0) == args[1] }),
          let items = children(menu).first.map(children) else { fail("no menu \(args[1])") }
    if args.count < 3 {
        items.map(title).filter { !$0.isEmpty }.forEach { print($0) }
    } else if let item = items.first(where: { title($0) == args[2] }) {
        press(item)
    } else { fail("no item \(args[2])") }
case "button":
    // Presses a button in any Shotty window, such as an alert's Discard.
    guard args.count > 1 else { fail("usage: button <title>") }
    func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        if (attribute(element, kAXRoleAttribute) as String?) == "AXButton", title(element) == args[1] { return element }
        guard depth < 10 else { return nil }
        return children(element).lazy.compactMap { find($0, depth: depth + 1) }.first
    }
    guard let button = ((attribute(app().1, kAXWindowsAttribute) as [AXUIElement]?) ?? []).lazy
        .compactMap({ find($0, depth: 0) }).first else { fail("no button \(args[1])") }
    press(button)
case "windows":
    // Shotty's on-screen windows: id, layer, frame, title. Pass a bundle ID for another app.
    let pid = app(args.count > 1 ? args[1] : bundleID).0.processIdentifier
    for info in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    where info[kCGWindowOwnerPID as String] as? Int32 == pid {
        let bounds = CGRect(dictionaryRepresentation: info[kCGWindowBounds as String] as! CFDictionary) ?? .zero
        print(info[kCGWindowNumber as String]!, info[kCGWindowLayer as String]!,
              Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height), info[kCGWindowName as String] ?? "")
    }
case "resize":
    guard args.count > 3, let window = window(named: args[1]) else { fail("usage: resize <title> w h") }
    var size = CGSize(width: number(2), height: number(3))
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    var actual = CGSize.zero
    if let value: AXValue = attribute(window, kAXSizeAttribute) { AXValueGetValue(value, .cgSize, &actual) }
    print(Int(actual.width), Int(actual.height))
case "close":
    guard args.count > 2, let button: AXUIElement = window(named: args[2], in: args[1]).flatMap({ attribute($0, kAXCloseButtonAttribute) })
    else { fail("usage: close <bundleID> <title>") }
    press(button)
case "focus":
    // Whether Shotty is active and which of its windows has focus; keyboard focus must not move there unasked.
    let (running, element) = app()
    let focused: AXUIElement? = attribute(element, kAXFocusedWindowAttribute)
    print("active=\(running.isActive) focused=\(focused.map(title) ?? "none")")
case "front":
    print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")
case "text":
    // The first text area in an app's focused window, to check where typing went.
    guard args.count > 1, let window: AXUIElement = attribute(app(args[1]).1, kAXFocusedWindowAttribute) else { fail("usage: text <bundleID>") }
    func find(_ element: AXUIElement, depth: Int) -> String? {
        if (attribute(element, kAXRoleAttribute) as String?) == "AXTextArea" { return attribute(element, kAXValueAttribute) }
        guard depth < 8 else { return nil }
        return children(element).lazy.compactMap { find($0, depth: depth + 1) }.first
    }
    print(find(window, depth: 0) ?? "")
case "cursor":
    // The capture crosshair is 23×23 points; the arrow is 28×40.
    let size = NSCursor.currentSystem?.image.size ?? .zero
    print(size.width == 23 ? "crosshair" : "other \(Int(size.width))x\(Int(size.height))")
case "clip":
    // `clip mark` before an action, then `clip wait out.png` saves the next clipboard image.
    let board = NSPasteboard.general
    if args.count > 1, args[1] == "mark" {
        try! String(board.changeCount).write(to: clipMark, atomically: true, encoding: .utf8)
    } else if args.count > 2, args[1] == "wait" {
        let mark = (try? String(contentsOf: clipMark, encoding: .utf8)).flatMap(Int.init) ?? board.changeCount
        let deadline = Date().addingTimeInterval(5)
        while board.changeCount == mark, Date() < deadline { usleep(50_000) }
        guard board.changeCount != mark, let data = board.data(forType: .png),
              let image = NSBitmapImageRep(data: data) else { fail("no new clipboard image") }
        try! data.write(to: URL(fileURLWithPath: args[2]))
        print(image.pixelsWide, image.pixelsHigh)
    } else { fail("usage: clip mark | clip wait <out.png>") }
default:
    fail("""
    usage: shotty-ui <command>
      move x y | click x y | drag x1 y1 x2 y2 [steps]
      menu <menu> [item] | button <title> | windows [bundleID] | resize <title> w h | close <bundleID> <title>
      focus | front | text <bundleID> | cursor | clip mark | clip wait <out.png>
      keys <text> | key <code> [command,shift,option,control]
      record <display> <seconds> <out.mov> | motion <mov> x y w h | frames <mov> <first> <last> x y w h <out.png>
    """)
}
