import Foundation

/// Builds ESC/POS byte streams for thermal receipt printers (Epson, Star in ESC/POS mode,
/// and most generic 58 mm / 80 mm printers). Text is folded to plain ASCII so every code page
/// prints it correctly.
struct EscPos {
    enum Alignment: UInt8 {
        case left = 0
        case center = 1
        case right = 2
    }

    private(set) var data = Data()

    static let esc: UInt8 = 0x1B
    static let gs: UInt8 = 0x1D
    static let lineFeed: UInt8 = 0x0A

    init() {
        initialize()
    }

    /// ESC @ — reset the printer to its defaults.
    mutating func initialize() {
        data.append(contentsOf: [Self.esc, 0x40])
    }

    /// ESC a n — left / center / right.
    mutating func align(_ alignment: Alignment) {
        data.append(contentsOf: [Self.esc, 0x61, alignment.rawValue])
    }

    /// ESC E n — emphasized (bold) on/off.
    mutating func bold(_ on: Bool) {
        data.append(contentsOf: [Self.esc, 0x45, on ? 1 : 0])
    }

    /// GS ! n — character size. `doubleWidth`/`doubleHeight` double each dimension.
    mutating func size(doubleWidth: Bool, doubleHeight: Bool) {
        let value: UInt8 = (doubleWidth ? 0x10 : 0) | (doubleHeight ? 0x01 : 0)
        data.append(contentsOf: [Self.gs, 0x21, value])
    }

    /// Text followed by a line feed.
    mutating func line(_ text: String = "") {
        data.append(Self.ascii(text))
        data.append(Self.lineFeed)
    }

    /// ESC d n — feed `lines` blank lines.
    mutating func feed(_ lines: UInt8) {
        data.append(contentsOf: [Self.esc, 0x64, lines])
    }

    /// GS V 66 n — feed 3 lines and do a partial cut (supported by Epson and Star ESC/POS).
    mutating func cut() {
        data.append(contentsOf: [Self.gs, 0x56, 0x42, 0x03])
    }

    /// ESC p 0 t1 t2 — pulse the cash drawer connected to the printer's drawer port.
    mutating func openCashDrawer() {
        data.append(contentsOf: [Self.esc, 0x70, 0x00, 0x19, 0xFA])
    }

    // MARK: - Text helpers

    /// Folds accents ("café" → "cafe"), maps common punctuation, and replaces anything else
    /// outside printable ASCII with "?".
    static func ascii(_ text: String) -> Data {
        let replacements: [Character: String] = [
            "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"",
            "\u{2013}": "-", "\u{2014}": "-", "\u{2026}": "...", "\u{00A0}": " ",
            "\u{2192}": "->", "\u{00B7}": "-", "\u{2022}": "*", "\u{20AC}": "EUR", "\u{00A3}": "GBP",
        ]
        var output = ""
        for character in text {
            if let replacement = replacements[character] {
                output += replacement
                continue
            }
            let folded = String(character).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en_US"))
            for scalar in folded.unicodeScalars {
                if scalar.value >= 0x20, scalar.value < 0x7F {
                    output.unicodeScalars.append(scalar)
                } else if scalar.value == 0x09 {
                    output += " "
                } else {
                    output += "?"
                }
            }
        }
        return Data(output.utf8)
    }
}
