@testable import TieDown
import XCTest

final class EscPosTests: XCTestCase {
    func testStartsWithInitialize() {
        XCTAssertEqual(Array(EscPos().data), [0x1B, 0x40])
    }

    func testCommandBytes() {
        var printer = EscPos()
        printer.align(.center)
        printer.bold(true)
        printer.size(doubleWidth: true, doubleHeight: true)
        printer.cut()
        printer.openCashDrawer()
        XCTAssertEqual(Array(printer.data), [
            0x1B, 0x40, // init
            0x1B, 0x61, 0x01, // center
            0x1B, 0x45, 0x01, // bold on
            0x1D, 0x21, 0x11, // double width + height
            0x1D, 0x56, 0x42, 0x03, // feed + partial cut
            0x1B, 0x70, 0x00, 0x19, 0xFA, // drawer pulse
        ])
    }

    func testLineAppendsLineFeed() {
        var printer = EscPos()
        printer.line("Hi")
        XCTAssertEqual(Array(printer.data.suffix(3)), [0x48, 0x69, 0x0A])
    }

    func testAsciiFoldsAccentsAndPunctuation() {
        XCTAssertEqual(String(decoding: EscPos.ascii("Café “Déjà” – 2 × €5…"), as: UTF8.self), "Cafe \"Deja\" - 2 ? EUR5...")
    }

    func testAsciiNeverEmitsControlOrNonAsciiBytes() {
        let bytes = EscPos.ascii("Tab\there 😀 ñ\u{0007}")
        XCTAssertTrue(bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F })
    }
}
