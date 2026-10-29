// Run: swift re/raw/engine/axless/probe.swift inventory|snapshot|activate|switches|wechat [bundleID]
// No text/AXValue/title payloads logged. No input events or content actions.
import AppKit
import ApplicationServices
import Foundation
func wait(_ seconds:Double) { RunLoop.current.run(until:Date().addingTimeInterval(seconds)) }
func emit(_ x: [String: Any]) { let d = try! JSONSerialization.data(withJSONObject:x, options:[.sortedKeys]); print(String(data:d,encoding:.utf8)!); fflush(stdout) }
func get(_ e: AXUIElement,_ k: String)->(AXError,CFTypeRef?) { var v:CFTypeRef?; let err=AXUIElementCopyAttributeValue(e,k as CFString,&v); return (err,v) }
func arr(_ e:AXUIElement,_ k:String)->[AXUIElement] { get(e,k).1 as? [AXUIElement] ?? [] }
func scalar(_ e:AXUIElement,_ k:String)->[String:Any] { let (err,v)=get(e,k); var b=DarwinBoolean(false);let s=AXUIElementIsAttributeSettable(e,k as CFString,&b); return ["error":err.rawValue,"value":(v as? NSNumber)?.stringValue ?? "nil","settableError":s.rawValue,"settable":b.boolValue] }
func tree(_ roots:[AXUIElement])->[String:Any] { var stack=roots.map{($0,0)};var seen=Set<AXUIElement>();var roles=[String:Int]();var errors=[String:Int](); let start=Date();var depthCut=false
 while let (e,depth)=stack.popLast() { if seen.contains(e){continue};seen.insert(e);let (err,r)=get(e,"AXRole");if err != .success { errors[String(err.rawValue),default:0]+=1 };roles[r as? String ?? "?",default:0]+=1
 if depth>=35 {depthCut=true;continue};if seen.count>=6000 || Date().timeIntervalSince(start)>8 {return ["nodes":seen.count,"roles":roles,"errors":errors,"truncated":true,"elapsed":Date().timeIntervalSince(start)]};stack += arr(e,"AXChildren").map{($0,depth+1)} }
 return ["nodes":seen.count,"roles":roles,"errors":errors,"truncated":depthCut,"elapsed":Date().timeIntervalSince(start)] }
let keys=["AXEnhancedUserInterface","AXManualAccessibility"]
func snapshot(_ app:NSRunningApplication,_ label:String) {
 let e=AXUIElementCreateApplication(app.processIdentifier);AXUIElementSetMessagingTimeout(e,0.4)
 var names:CFArray?;let ne=AXUIElementCopyAttributeNames(e,&names);let ns=names as? [String] ?? [];let ws=arr(e,"AXWindows");let children=arr(e,"AXChildren")
 let cg=(CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []).filter{($0[kCGWindowOwnerPID as String] as? Int)==Int(app.processIdentifier) && ($0[kCGWindowLayer as String] as? Int)==0}.map{["id":$0[kCGWindowNumber as String] ?? 0,"onscreen":$0[kCGWindowIsOnscreen as String] ?? false,"bounds":$0[kCGWindowBounds as String] ?? [:]] as [String:Any]}
 var out:[String:Any]=["time":ISO8601DateFormatter().string(from:Date()),"label":label,"bundle":app.bundleIdentifier ?? "?","pid":app.processIdentifier,"active":app.isActive,"hidden":app.isHidden,"frontmost":NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?","windows":ws.count,"windowsError":get(e,"AXWindows").0.rawValue,"childRoles":children.map{get($0,"AXRole").1 as? String ?? "?"},"windowTree":tree(ws),"appTree":tree([e]),"cgWindows":cg,"attributeNamesError":ne.rawValue]
 for k in keys { var d=scalar(e,k);d["advertised"]=ns.contains(k);out[k]=d };emit(out)
}
func activate(_ a:NSRunningApplication) { emit(["action":"activate","bundle":a.bundleIdentifier ?? "?","accepted":a.activate(options:[.activateIgnoringOtherApps])]);wait(0.8) }
let args=CommandLine.arguments;let mode=args.count>1 ? args[1]:"inventory"
let chrome=NSRunningApplication.runningApplications(withBundleIdentifier:"com.google.Chrome").first
if mode=="inventory" { for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {emit(["bundle":a.bundleIdentifier ?? "?","name":a.localizedName ?? "?","pid":a.processIdentifier,"active":a.isActive,"hidden":a.isHidden,"path":a.bundleURL?.path ?? "?"])};emit(["trusted":AXIsProcessTrusted(),"os":ProcessInfo.processInfo.operatingSystemVersionString]);exit(0) }
let id=args.count>2 ? args[2]:"com.tencent.xinWeChat"
guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:id).first else {emit(["notRunning":id]);exit(0)}
if mode=="manual-timing" {
 let e=AXUIElementCreateApplication(app.processIdentifier);let key="AXManualAccessibility";let (err,old)=get(e,key)
 guard err == .success,let old=old else {emit(["skip":key]);exit(0)}
 snapshot(app,"timing-baseline");let started=Date();emit(["action":"set-true","key":key,"error":AXUIElementSetAttributeValue(e,key as CFString,kCFBooleanTrue).rawValue])
 for delay in [0.0,0.1,0.3,0.6,1.2,1.8,2.1,2.5,3.2] {wait(max(0,delay-Date().timeIntervalSince(started)));snapshot(app,"at-\(String(format:"%.3f",Date().timeIntervalSince(started)))s")}
 emit(["action":"restore-switch","key":key,"error":AXUIElementSetAttributeValue(e,key as CFString,old).rawValue]);wait(0.5);snapshot(app,"timing-restored");exit(0)
}
if mode=="snapshot" {snapshot(app,"snapshot");exit(0)}
if mode=="activate" { snapshot(app,"before");activate(app);snapshot(app,"foreground");if let c=chrome {activate(c)};snapshot(app,"background-after");exit(0) }
if mode=="wechat" {
 activate(app);snapshot(app,"foreground-warm")
 if let c=chrome {activate(c)};snapshot(app,"background-0.8s");wait(5);snapshot(app,"background-5s");wait(25);snapshot(app,"background-30s")
 activate(app);let e=AXUIElementCreateApplication(app.processIdentifier);let windows=arr(e,"AXWindows");
 if let w=windows.first {let old=get(w,"AXMinimized").1;var set=DarwinBoolean(false);AXUIElementIsAttributeSettable(w,"AXMinimized" as CFString,&set);if set.boolValue,let old=old {emit(["action":"minimize","error":AXUIElementSetAttributeValue(w,"AXMinimized" as CFString,kCFBooleanTrue).rawValue]);wait(0.8);snapshot(app,"minimized");emit(["action":"restore-minimized","error":AXUIElementSetAttributeValue(w,"AXMinimized" as CFString,old).rawValue]);wait(0.8)}}
 let wasHidden=app.isHidden;emit(["action":"hide","accepted":app.hide()]);wait(0.8);snapshot(app,"hidden");if !wasHidden {emit(["action":"unhide","accepted":app.unhide()])};activate(app);snapshot(app,"restored");if let c=chrome {activate(c)};exit(0)
}
if mode=="switches" {
 let e=AXUIElementCreateApplication(app.processIdentifier);AXUIElementSetMessagingTimeout(e,0.4);snapshot(app,"switch-baseline")
 for key in keys {let (err,old)=get(e,key);guard err == .success,let old=old,CFGetTypeID(old)==CFBooleanGetTypeID() else {emit(["skip":key,"reason":"no restorable Boolean","error":err.rawValue]);continue}
 emit(["action":"set-true","key":key,"error":AXUIElementSetAttributeValue(e,key as CFString,kCFBooleanTrue).rawValue]);snapshot(app,"\(key)-immediate");wait(0.2);snapshot(app,"\(key)-200ms");wait(1);snapshot(app,"\(key)-1200ms");activate(app);snapshot(app,"\(key)-foreground");if let c=chrome {activate(c)};wait(2);snapshot(app,"\(key)-background-2s");emit(["action":"restore-switch","key":key,"error":AXUIElementSetAttributeValue(e,key as CFString,old).rawValue]);wait(0.3);snapshot(app,"\(key)-restored") }
 if let c=chrome {activate(c)}
}
