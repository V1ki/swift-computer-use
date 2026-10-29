// Read-only: capture in memory, OCR aggregate only; no screenshot/text persists.
import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import Foundation
func emit(_ x:[String:Any]) {print(String(data:try! JSONSerialization.data(withJSONObject:x,options:.sortedKeys),encoding:.utf8)!);fflush(stdout)}
func get(_ e:AXUIElement,_ k:String)->CFTypeRef? {var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,k as CFString,&v);return v}
_ = NSApplication.shared
_ = NSScreen.screens
let id=CommandLine.arguments.count>1 ? CommandLine.arguments[1]:"md.obsidian"
guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:id).first else {exit(0)}
let ax=AXUIElementCreateApplication(app.processIdentifier);AXUIElementSetMessagingTimeout(ax,0.2)
var q=(get(ax,"AXChildren") as? [AXUIElement] ?? []).filter{get($0,"AXRole") as? String == "AXMenuBar"};var seen=Set<AXUIElement>();var shortcuts=[[String:Any]]()
while let e=q.popLast() {if seen.contains(e){continue};seen.insert(e);if let char=get(e,"AXMenuItemCmdChar") as? String,!char.isEmpty {shortcuts.append(["char":char,"modifiers":(get(e,"AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? -1,"virtualKey":(get(e,"AXMenuItemCmdVirtualKey") as? NSNumber)?.intValue ?? -1])};q += get(e,"AXChildren") as? [AXUIElement] ?? []}
emit(["bundle":id,"menuNodes":seen.count,"shortcuts":shortcuts])
guard CGPreflightScreenCaptureAccess() else {emit(["screenCapture":"not-authorized-no-prompt"]);exit(0)}
Task {
 do {let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
 let candidates=content.windows.filter{$0.owningApplication?.processID==app.processIdentifier && $0.frame.width>100 && $0.frame.height>100}
 let requested=CommandLine.arguments.count>2 ? UInt32(CommandLine.arguments[2]):nil
 guard let w=(requested == nil ? candidates.max(by:{$0.frame.width*$0.frame.height<$1.frame.width*$1.frame.height}):candidates.first(where:{$0.windowID==requested!})) else {emit(["capture":"no-window"]);exit(0)}
 let filter=SCContentFilter(desktopIndependentWindow:w);let config=SCStreamConfiguration();config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.width=Int(w.frame.width*2);config.height=Int(w.frame.height*2)
 let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
 let req=VNRecognizeTextRequest();req.recognitionLevel = .accurate;req.recognitionLanguages=["zh-Hans","en-US"];let start=Date();try VNImageRequestHandler(cgImage:image,options:[:]).perform([req]);let obs=req.results ?? []
 emit(["bundle":id,"windowID":w.windowID,"frame":[w.frame.minX,w.frame.minY,w.frame.width,w.frame.height],"pixels":[image.width,image.height],"OCRboxes":obs.count,"confidentBoxes":obs.filter{($0.topCandidates(1).first?.confidence ?? 0)>0.8}.count,"OCRseconds":Date().timeIntervalSince(start),"storage":"memory-only-no-image-or-text-written"])
 } catch {emit(["error":String(describing:error)])};exit(0)
}
RunLoop.main.run()
