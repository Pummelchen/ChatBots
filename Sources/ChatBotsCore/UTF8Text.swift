// ChatBotsCore — keeping text whole across the places it gets cut
//
// Swift strings are Unicode-correct by default, so the risk here is not the model or the
// log — it is the app's own shortening. Two shapes of bug are easy to write and easy to
// miss, because both look fine on ASCII:
//
//   * truncating *bytes* (`data.prefix(400)`) can split a multi-byte character, and
//     `String(data:encoding:.utf8)` then fails outright or yields a replacement character;
//   * truncating by `count` is safer, but `String.count` is grapheme clusters — fine for a
//     character budget, and worth stating so it is not mistaken for bytes or scalars.
//
// Everything that shortens text goes through here, so there is one place to get right.

import Foundation

public enum UTF8Text {

    /// Text shortened to at most `limit` grapheme clusters, with an ellipsis when it was
    /// cut. Never splits a character, an emoji, or a combining sequence.
    public static func prefix(_ text: String, _ limit: Int, ellipsis: String = "…") -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + ellipsis
    }

    /// Decode UTF-8 that may have been cut mid-character.
    ///
    /// A partial trailing sequence is dropped rather than turned into `U+FFFD`: it is not
    /// the text's fault that it was truncated, and printing "Server returned HTTP 500:
    /// …caf\u{FFFD}" is worse than printing the part that was actually received. Returns
    /// nil only when the bytes are not UTF-8 at all.
    public static func decodeTruncated(_ data: Data) -> String? {
        if let whole = String(data: data, encoding: .utf8) { return whole }
        // Walk back over at most a few bytes — an incomplete sequence can only be the
        // final 1–3 bytes of a 4-byte encoding.
        for dropLast in 1...min(3, data.count) {
            let candidate = data.dropLast(dropLast)
            if let decoded = String(data: candidate, encoding: .utf8) { return decoded }
        }
        return nil
    }

    /// Bytes shortened to at most `limit` bytes without splitting a character.
    public static func bytePrefix(_ data: Data, _ limit: Int) -> Data {
        guard data.count > limit else { return data }
        let cut = data.prefix(limit)
        // A byte cut can land inside a character; re-encoding the decoded text is the
        // simplest way to guarantee what remains is valid UTF-8.
        guard let decoded = decodeTruncated(Data(cut)) else { return Data(cut.prefix(0)) }
        return Data(decoded.utf8)
    }
}
