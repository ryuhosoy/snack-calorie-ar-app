import Foundation

/// data/build_snacks.py の normalize() と同じ規則で文字列を正規化する。
/// NFKC → 小文字 → カタカナをひらがなに → 文字・数字・長音以外を除去
enum TextNormalizer {
  static func normalize(_ s: String) -> String {
    let nfkc = s.precomposedStringWithCompatibilityMapping.lowercased()
    var out = String.UnicodeScalarView()
    for scalar in nfkc.unicodeScalars {
      var sc = scalar
      if (0x30A1...0x30F6).contains(sc.value), let h = Unicode.Scalar(sc.value - 0x60) {
        sc = h
      }
      if keep(sc) { out.append(sc) }
    }
    return String(out)
  }

  private static func keep(_ sc: Unicode.Scalar) -> Bool {
    let v = sc.value
    if sc == "ー" { return true }
    if (0x3040...0x30FF).contains(v) || (0x4E00...0x9FFF).contains(v) { return true }
    switch sc.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
         .decimalNumber, .letterNumber, .otherNumber:
      return true
    default:
      return false
    }
  }

  /// 連続2文字の集合（照合スコアに使う）
  static func bigrams(_ s: String) -> Set<String> {
    let chars = Array(s)
    guard chars.count >= 2 else { return chars.isEmpty ? [] : [s] }
    var set = Set<String>()
    for i in 0..<(chars.count - 1) { set.insert(String(chars[i...i + 1])) }
    return set
  }

  /// FTS5 trigram 用の3文字片
  static func trigrams(_ s: String, limit: Int = 150) -> [String] {
    let chars = Array(s)
    guard chars.count >= 3 else { return [] }
    var seen = Set<String>()
    var out: [String] = []
    for i in 0..<(chars.count - 2) {
      let t = String(chars[i...i + 2])
      if seen.insert(t).inserted { out.append(t) }
      if out.count >= limit { break }
    }
    return out
  }
}
