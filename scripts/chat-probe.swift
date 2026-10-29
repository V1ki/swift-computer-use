import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, name as CFString, &v); return v }
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func front(_ phase: String) {
 let a = NSWorkspace.shared.frontmostApplication!
 print("\(ISO8601DateFormatter().string(from: Date())) \(phase) NSWorkspace=\(a.localizedName ?? "?") PID=\(a.processIdentifier)")
 let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", "tell application \"System Events\"", "-e", "set p to first application process whose frontmost is true", "-e", "return {name of p, unix id of p}", "-e", "end tell"]; try! p.run(); p.waitUntilExit()
 guard a.bundleIdentifier != "com.tencent.xinWeChat" else { fatalError("WeChat foreground; stop") }
}
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat").first!
let root = AXUIElementCreateApplication(app.processIdentifier)
let windows = attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
var nodes: [AXUIElement] = []
func walk(_ e: AXUIElement, _ depth: Int) { let i = nodes.count; nodes.append(e); print("\(i) \(String(repeating: " ", count: depth))\(attr(e,kAXRoleAttribute) ?? "?" as NSString) title=\(attr(e,kAXTitleAttribute) ?? "" as NSString) value=\(attr(e,kAXValueAttribute) ?? "" as NSString) desc=\(attr(e,kAXDescriptionAttribute) ?? "" as NSString)"); if depth < 18 { children(e).forEach { walk($0,depth+1) } } }
front("before")
windows.forEach { walk($0,0) }
let args = CommandLine.arguments
if args.count > 2 {
 let cmd = args[1]
 if cmd == "set" || cmd == "focus" { let e = args[2] == "search" ? nodes.first { (attr($0,kAXTitleAttribute) as? String) == "搜索" && (attr($0,kAXRoleAttribute) as? String) == "AXTextArea" }! : nodes[Int(args[2])!]; if cmd == "set" { print("set=\(AXUIElementSetAttributeValue(e,kAXValueAttribute as CFString,args[3] as CFString).rawValue)") } else { print("focus=\(AXUIElementSetAttributeValue(e,kAXFocusedAttribute as CFString,kCFBooleanTrue).rawValue)") } }
 if cmd == "listfocus" { let list = nodes.first { (attr($0,kAXRoleAttribute) as? String) == "AXList" && (attr($0,kAXTitleAttribute) as? String) == "会话" }!; print("listfocus=\(AXUIElementSetAttributeValue(list,kAXFocusedAttribute as CFString,kCFBooleanTrue).rawValue)") }
 if cmd == "attrs" { let e = args[2] == "search" ? nodes.first { (attr($0,kAXTitleAttribute) as? String) == "搜索" }! : nodes[Int(args[2])!]; var names: CFArray?; AXUIElementCopyAttributeNames(e,&names); for name in names as? [String] ?? [] { print("ATTR \(name)=\(String(describing:attr(e,name)))") }; AXUIElementCopyActionNames(e,&names); print("ACTIONS \(String(describing:names))") }
 if cmd == "select" { let row = nodes.first { (attr($0,kAXTitleAttribute) as? String)?.components(separatedBy: "\n").first == args[2] }!; print("select=\(AXUIElementSetAttributeValue(row,kAXSelectedAttribute as CFString,kCFBooleanTrue).rawValue)"); print("press=\(AXUIElementPerformAction(row,kAXPressAction as CFString).rawValue)") }
 if cmd == "key" { let code = CGKeyCode(args[2])!; for down in [true,false] { let e = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!; e.postToPid(app.processIdentifier); usleep(30000) } }
}
let focused = attr(root,kAXFocusedUIElementAttribute)
print("focused element=\(String(describing: focused))")
if let focused { let e = unsafeDowncast(focused, to: AXUIElement.self); print("focused role=\(attr(e,kAXRoleAttribute) ?? "" as NSString) title=\(attr(e,kAXTitleAttribute) ?? "" as NSString) value=\(attr(e,kAXValueAttribute) ?? "" as NSString)") }
front("after")
