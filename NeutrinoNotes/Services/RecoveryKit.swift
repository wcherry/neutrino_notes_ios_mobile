import Foundation

// MARK: - RecoveryKit
//
// The keyring on paper — and, with nothing stored server-side, the only copy
// that survives losing every device.
//
// It carries the *whole* keyring, not just the current key: a file sealed to
// version 1 needs version 1, and a kit that restored only the newest key would
// come back to a library it cannot open.
//
// The encoding must match `web/packages/e2e-crypto/src/recoveryKit.ts` exactly,
// since a kit printed on the web is typed in here. It is a compact binary frame
// in Crockford base32 rather than the serialised JSON — a three-version keyring
// is 108 bytes this way against roughly 400 as JSON, and that difference is what
// someone has to copy by hand without a transcription error.
//
//   byte 0      magic 'N' (0x4E)
//   byte 1      format version (1)
//   byte 2      entry count
//   per entry   version (2 bytes, big-endian) | secret key (32) | flags (1)
//               flags bit 0 = retired
//
// Timestamps are deliberately absent. They are display metadata, not key
// material, and spending a third of the printed length on them would be paying
// paper for something nobody needs to recover a file. Restored entries are
// stamped with the moment of the restore instead.

enum RecoveryKitError: LocalizedError {
    case notAKit
    case unsupportedVersion(Int)
    case incomplete
    case damaged
    case unexpectedCharacter(Character)

    var errorDescription: String? {
        switch self {
        case .notAKit:
            return "This does not look like a Neutrino recovery kit."
        case .unsupportedVersion(let v):
            return "This recovery kit uses format version \(v), which this app does not understand."
        case .incomplete:
            return "This recovery kit is incomplete — some characters are missing."
        case .damaged:
            return "This recovery kit is damaged — it does not name exactly one current key."
        case .unexpectedCharacter(let c):
            return "This recovery kit contains an unexpected character: \(c)"
        }
    }
}

enum RecoveryKit {

    /// Crockford base32 — no I, L, O or U.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let groupSize = 4
    private static let groupsPerLine = 8

    private static let magic: UInt8 = 0x4E   // 'N'
    private static let formatVersion: UInt8 = 1
    private static let secretKeyBytes = 32
    private static let entryBytes = 2 + 32 + 1
    private static let flagRetired: UInt8 = 0x01

    // MARK: Normalisation

    /// Fold the common misreadings back before decoding.
    ///
    /// Crockford's whole point is that these characters are unambiguous *if* you
    /// map them: someone copying off paper writes O for 0 and l for 1 regardless
    /// of what the alphabet says.
    static func normalize(_ text: String) -> String {
        var s = text.uppercased()
        s = s.filter { !$0.isWhitespace && $0 != "-" }
        s = s.replacingOccurrences(of: "O", with: "0")
        s = s.replacingOccurrences(of: "I", with: "1")
        s = s.replacingOccurrences(of: "L", with: "1")
        s = s.replacingOccurrences(of: "U", with: "V")
        return s
    }

    // MARK: base32

    private static func encodeBase32(_ bytes: [UInt8]) -> String {
        var bits = 0
        var value = 0
        var out = ""
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        // Pad the trailing partial group with zero bits rather than dropping it
        // — those bits are key material.
        if bits > 0 {
            out.append(alphabet[(value << (5 - bits)) & 31])
        }
        return out
    }

    private static func decodeBase32(_ text: String) throws -> [UInt8] {
        var bits = 0
        var value = 0
        var out: [UInt8] = []
        for char in text {
            guard let index = alphabet.firstIndex(of: char) else {
                throw RecoveryKitError.unexpectedCharacter(char)
            }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }

    // MARK: Export

    /// Render `keyring` as the printable kit, grouped in fours and wrapped —
    /// this is copied by eye, and an unbroken 170-character string is where
    /// transcription errors come from.
    static func export(_ keyring: Keyring) -> String {
        var frame: [UInt8] = [magic, formatVersion, UInt8(keyring.entries.count)]
        for entry in keyring.entries {
            frame.append(UInt8((entry.version >> 8) & 0xFF))
            frame.append(UInt8(entry.version & 0xFF))
            frame.append(contentsOf: entry.secretKey)
            frame.append(entry.isActive ? 0 : flagRetired)
        }

        let encoded = Array(encodeBase32(frame))
        var groups: [String] = []
        var i = 0
        while i < encoded.count {
            groups.append(String(encoded[i..<min(i + groupSize, encoded.count)]))
            i += groupSize
        }

        var lines: [String] = []
        var g = 0
        while g < groups.count {
            lines.append(groups[g..<min(g + groupsPerLine, groups.count)].joined(separator: "-"))
            g += groupsPerLine
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Import

    /// Rebuild a keyring from a printed kit.
    ///
    /// `userId` comes from the signed-in session rather than the kit: the kit
    /// holds key material only, and binding it to an account is the caller's
    /// business.
    static func importKit(_ text: String, userId: String) throws -> Keyring {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { throw RecoveryKitError.notAKit }

        let bytes = try decodeBase32(normalized)
        guard bytes.count >= 3, bytes[0] == magic else { throw RecoveryKitError.notAKit }
        guard bytes[1] == formatVersion else {
            throw RecoveryKitError.unsupportedVersion(Int(bytes[1]))
        }

        let count = Int(bytes[2])
        // A truncated kit is the likely outcome of copying by hand, so say that
        // rather than letting a short read produce a subtly wrong key.
        guard bytes.count >= 3 + count * entryBytes else { throw RecoveryKitError.incomplete }

        let now = ISO8601DateFormatter().string(from: Date())
        var entries: [KeyringEntry] = []
        var offset = 3
        for _ in 0..<count {
            let version = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            let secretKey = Array(bytes[(offset + 2)..<(offset + 2 + secretKeyBytes)])
            let retired = (bytes[offset + 2 + secretKeyBytes] & flagRetired) != 0
            guard let publicKey = KeyringCoder.publicKey(fromSecret: secretKey) else {
                throw RecoveryKitError.damaged
            }
            entries.append(KeyringEntry(
                version: version,
                publicKey: publicKey,
                secretKey: secretKey,
                createdAt: now,
                retiredAt: retired ? now : nil
            ))
            offset += entryBytes
        }

        guard entries.filter(\.isActive).count == 1 else { throw RecoveryKitError.damaged }
        entries.sort { $0.version < $1.version }
        return Keyring(userId: userId, entries: entries)
    }

    /// True if `text` could plausibly be a kit, for deciding which field to accept.
    static func looksLikeKit(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard normalized.count >= 60 else { return false }
        return normalized.allSatisfy { alphabet.contains($0) }
    }
}
