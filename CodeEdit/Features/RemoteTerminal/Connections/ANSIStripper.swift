//
//  ANSIStripper.swift
//  CodeEdit
//

import Foundation

/// Strips ANSI/VT100 escape sequences from a byte slice, returning plain UTF-8 text.
enum ANSIStripper {
    static func strip(_ bytes: ArraySlice<UInt8>) -> String {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var idx = bytes.startIndex

        while idx < bytes.endIndex {
            let byte = bytes[idx]
            if byte == 0x1B {
                idx = bytes.index(after: idx)
                guard idx < bytes.endIndex else { break }
                let next = bytes[idx]
                if next == 0x5B || next == 0x4F {
                    // CSI sequence (ESC [ ...) or SS3 (ESC O ...)
                    idx = bytes.index(after: idx)
                    // Skip parameter/intermediate bytes (0x20–0x3F), stop at command byte (0x40–0x7E)
                    while idx < bytes.endIndex && !(0x40...0x7E).contains(bytes[idx]) {
                        idx = bytes.index(after: idx)
                    }
                    if idx < bytes.endIndex { idx = bytes.index(after: idx) }
                } else if (0x40...0x5F).contains(next) {
                    // Two-byte escape sequence (ESC + Fe)
                    idx = bytes.index(after: idx)
                } else if next == 0x5D {
                    // OSC sequence (ESC ] ... ST or BEL)
                    idx = bytes.index(after: idx)
                    while idx < bytes.endIndex && bytes[idx] != 0x07 && bytes[idx] != 0x1B {
                        idx = bytes.index(after: idx)
                    }
                    if idx < bytes.endIndex && bytes[idx] == 0x1B {
                        idx = bytes.index(after: idx) // skip ESC of ESC\
                        if idx < bytes.endIndex { idx = bytes.index(after: idx) } // skip backslash
                    } else if idx < bytes.endIndex {
                        idx = bytes.index(after: idx) // skip BEL
                    }
                }
            } else {
                result.append(byte)
                idx = bytes.index(after: idx)
            }
        }
        return String(bytes: result, encoding: .utf8) ?? String(bytes: result, encoding: .isoLatin1) ?? ""
    }
}
