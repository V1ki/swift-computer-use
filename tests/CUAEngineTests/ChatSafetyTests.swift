import XCTest
import CUACore
@testable import CUAEngine

final class ChatSafetyTests: XCTestCase {
    func testExactFirstLineAndUniqueSelection() throws {
        XCTAssertEqual(try ChatSafety.matchingRow(["other", "Codex 零号远征队\n12:00", "Codex"], name:"Codex 零号远征队"),1)
        XCTAssertThrowsError(try ChatSafety.matchingRow(["Codex 零号远征队 extra"],name:"Codex 零号远征队"))
        XCTAssertThrowsError(try ChatSafety.matchingRow(["knight", "knight\npreview"],name:"knight"))
    }
    func testSendRequiresAllowlistAndExactTitle() throws {
        try ChatSafety.validateSend(chat:"文件传输助手",title:"文件传输助手")
        try ChatSafety.validateSend(chat:"knight",title:"knight")
        XCTAssertThrowsError(try ChatSafety.validateSend(chat:"Codex 零号远征队",title:"Codex 零号远征队"))
        XCTAssertThrowsError(try ChatSafety.validateSend(chat:"knight",title:"Codex 零号远征队"))
        XCTAssertThrowsError(try ChatSafety.validateSend(chat:"knight ",title:"knight "))
    }
    func testSendVerificationRequiresNewExactMessageAndClearedDraft() {
        XCTAssertTrue(ChatSafety.verifiedSend(before:["old"],after:["old","test"],text:"test",composer:""))
        XCTAssertFalse(ChatSafety.verifiedSend(before:["test"],after:["test"],text:"test",composer:""))
        XCTAssertFalse(ChatSafety.verifiedSend(before:[],after:["test suffix"],text:"test",composer:""))
        XCTAssertFalse(ChatSafety.verifiedSend(before:[],after:["test"],text:"test",composer:"test"))
    }
    func testBackgroundChatScopeRejectsGlobalMouse() throws {
        try InputSynthesis.$context.withValue(InputContext(allowActivation:false)) {
            XCTAssertThrowsError(try InputSynthesis.mouse(.leftMouseDown,at:.zero))
        }
    }
    func testChatProtocolRoundTrip() throws {
        let p = ChatParams(app:"com.tencent.xinWeChat",chat:"knight",text:"hello")
        XCTAssertEqual(try CUACodec.decode(ChatParams.self,from:CUACodec.encode(p)),p)
        XCTAssertEqual(CUAMethod(rawValue:"openChat"),.openChat)
        XCTAssertEqual(CUAMethod(rawValue:"sendText"),.sendText)
    }
}
