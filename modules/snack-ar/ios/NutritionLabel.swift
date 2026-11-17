import Foundation

/// 裏面の栄養成分表示から読み取った値
struct NutritionLabel: Codable {
  let kcal: Double
  /// 「1袋」「100g」「1個」など、表示の基準
  let basis: String
  let basisGrams: Double?
  let packGrams: Double?

  /// 1袋あたりに換算できれば換算
  var kcalPerPack: Int? {
    if ["1袋", "1箱", "1パック"].contains(basis) { return Int(kcal.rounded()) }
    if basis == "100g", let p = packGrams { return Int((kcal * p / 100).rounded()) }
    return nil
  }

  var displayText: String {
    if let k = kcalPerPack { return "1袋 \(k)kcal" }
    if let g = basisGrams, basis != "100g" { return "\(basis)(\(Self.fmt(g))g) \(Int(kcal.rounded()))kcal" }
    return "\(basis) \(Int(kcal.rounded()))kcal"
  }

  private static func fmt(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
  }
}

enum NutritionLabelParser {
  /// 「栄養成分表示 1袋(55g)当たり エネルギー 300kcal …」を読む
  static func parse(_ texts: [String]) -> NutritionLabel? {
    let joined = texts.joined(separator: "\n")
      .precomposedStringWithCompatibilityMapping
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "\u{3000}", with: "")
    let lower = joined.lowercased()
    guard lower.contains("kcal") || lower.contains("キロカロリー") else { return nil }
    // 表らしさの確認：エネルギー/熱量 か、たんぱく質・脂質などが一緒に写っていること
    let markers = ["エネルギー", "熱量", "たんぱく質", "蛋白質", "脂質", "炭水化物", "食塩相当量"]
    guard markers.filter({ joined.contains($0) }).count >= 2 else { return nil }

    let kcal: Double
    if let v = firstNumber(in: lower, pattern: #"(?:エネルギー|熱量)[^0-9]{0,6}([0-9]+(?:\.[0-9]+)?)(?:kcal|キロカロリー)"#) {
      kcal = v
    } else if let v = firstNumber(in: lower, pattern: #"([0-9]+(?:\.[0-9]+)?)(?:kcal|キロカロリー)"#) {
      kcal = v
    } else {
      return nil
    }
    guard kcal > 0, kcal < 3000 else { return nil }

    var basis = "100g"
    var basisGrams: Double? = 100
    let basisPattern = #"(1袋|1箱|1個|1本|1枚|1パック|1食|100g|100ml)(?:\(?(?:標準)?([0-9]+(?:\.[0-9]+)?)g\)?)?(?:当たり|あたり|当り)"#
    if let m = match(in: joined, pattern: basisPattern) {
      basis = m[1] ?? basis
      basisGrams = m[2].flatMap(Double.init) ?? (basis == "100g" ? 100 : nil)
    }
    let packGrams = firstNumber(in: joined, pattern: #"内容量[^0-9]{0,3}([0-9]+(?:\.[0-9]+)?)g"#)
    return NutritionLabel(kcal: kcal, basis: basis, basisGrams: basisGrams, packGrams: packGrams)
  }

  private static func firstNumber(in s: String, pattern: String) -> Double? {
    match(in: s, pattern: pattern)?[1].flatMap(Double.init)
  }

  private static func match(in s: String, pattern: String) -> [String?]? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
      Range(m.range(at: i), in: s).map { String(s[$0]) }
    }
  }
}

/// 裏面から読んだ「仮登録」データを端末に貯める。
/// 後でサーバー（Supabase など）へ送信 → 複数人一致で確定 → snacks.sqlite に差分配信、の入口。
final class PendingStore {
  static let shared = PendingStore()

  struct Entry: Codable {
    let id: String
    let createdAt: Date
    let label: NutritionLabel
    let barcode: String?
    let ocrText: String
    var status = "provisional"
  }

  private let queue = DispatchQueue(label: "snackar.pending")
  private var url: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("pending_back_labels.json")
  }

  func add(label: NutritionLabel, barcode: String?, texts: [String]) {
    queue.async {
      var all = self.load()
      let text = texts.joined(separator: "\n")
      // 同じ裏面を何度も保存しない
      if let last = all.last, last.ocrText == text { return }
      all.append(Entry(id: UUID().uuidString, createdAt: Date(), label: label, barcode: barcode, ocrText: text))
      if let data = try? JSONEncoder().encode(all) { try? data.write(to: self.url, options: .atomic) }
    }
  }

  private func load() -> [Entry] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }
}
