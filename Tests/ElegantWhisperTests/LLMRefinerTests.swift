@testable import ElegantWhisper
import XCTest

final class LLMRefinerTests: XCTestCase {
    func testAcceptsSmallConservativeCorrection() {
        let refiner = LLMRefiner(settings: .shared)

        XCTAssertTrue(refiner.acceptsCorrection(original: "我在写配森和杰森", corrected: "我在写 Python 和 JSON"))
    }

    func testRejectsEmptyCorrection() {
        let refiner = LLMRefiner(settings: .shared)

        XCTAssertFalse(refiner.acceptsCorrection(original: "hello world", corrected: ""))
    }

    func testRejectsLargeRewrite() {
        let refiner = LLMRefiner(settings: .shared)

        XCTAssertFalse(refiner.acceptsCorrection(
            original: "打开设置",
            corrected: "下面是一个完整的操作指南，第一步打开系统设置，第二步找到隐私权限，第三步逐项检查。"
        ))
    }
}
