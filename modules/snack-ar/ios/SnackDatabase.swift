import Foundation
import SQLite3

struct Snack: Equatable {
  let code: String
  let nameJa: String
  let brand: String?
  let packG: Double?
  let kcal100g: Double?
  let kcalServing: Double?
  let kcalPack: Int?
  let needsReview: Bool
  let nameNorm: String
  let flavors: [String]

  /// ラベルに出す主表示。「1袋 158kcal」→ 無ければ 1食 → 100g
  var calorieText: String {
    if let k = kcalPack { return "1袋 \(k)kcal" }
    if let k = kcalServing { return "1食 \(Int(k.rounded()))kcal" }
    if let k = kcal100g { return "100g \(Int(k.rounded()))kcal" }
    return "kcal不明"
  }

  static func == (a: Snack, b: Snack) -> Bool { a.code == b.code }
}

enum MatchResult {
  case confident(Snack)
  case ambiguous([Snack])
  case none
}

/// 同梱の snacks.sqlite（読み取り専用）を引く
final class SnackDatabase {
  static let shared = SnackDatabase()

  private var db: OpaquePointer?
  private let lock = NSLock()
  private(set) var isFTSAvailable = true

  private init() {
    guard let url = Self.databaseURL() else {
      NSLog("[SnackAR] snacks.sqlite が見つかりません")
      return
    }
    if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
      NSLog("[SnackAR] snacks.sqlite を開けません")
      db = nil
    }
  }

  private static func databaseURL() -> URL? {
    let bundles = [Bundle.main, Bundle(for: SnackDatabase.self)]
    for b in bundles {
      if let rb = b.url(forResource: "SnackARResources", withExtension: "bundle").flatMap(Bundle.init(url:)),
         let u = rb.url(forResource: "snacks", withExtension: "sqlite") {
        return u
      }
      if let u = b.url(forResource: "snacks", withExtension: "sqlite") { return u }
    }
    return nil
  }

  private static let columns =
    "s.code, s.name_ja, s.brand, s.pack_g, s.kcal_100g, s.kcal_serving, s.kcal_pack, s.needs_review, s.name_norm, s.flavors, s.popularity, s.brand_norm"

  // MARK: - バーコード（JAN）で完全一致

  func lookup(code: String) -> Snack? {
    lock.lock(); defer { lock.unlock() }
    return query("select \(Self.columns) from snacks s where s.code = ?1 limit 1", bind: [code]).first?.snack
  }

  // MARK: - 読めた文字列で照合

  func match(texts: [String]) -> MatchResult {
    let t = TextNormalizer.normalize(texts.joined())
    guard t.count >= 2 else { return .none }
    let tBigrams = TextNormalizer.bigrams(t)

    lock.lock()
    let rows = candidates(for: t)
    lock.unlock()

    struct Scored { let snack: Snack; let score: Double; let hits: Int; let popularity: Int }
    var scored: [Scored] = []
    for row in rows {
      let s = row.snack
      // 誤一致対策：候補名に入っている味名が、読めた文字に無ければ除外
      if s.flavors.contains(where: { !t.contains($0) }) { continue }
      let nb = TextNormalizer.bigrams(s.nameNorm)
      guard !nb.isEmpty else { continue }
      let hits = nb.intersection(tBigrams).count
      guard hits >= min(3, nb.count) else { continue }
      var score = Double(hits) / Double(nb.count)
      if let b = row.brandNorm, b.count >= 2, t.contains(b) { score += 0.05 }
      scored.append(Scored(snack: s, score: min(score, 1.0), hits: hits, popularity: row.popularity))
    }
    // スコア → 一致数（＝より具体的な名前）→ 1袋kcalがある → 人気 の順
    scored.sort {
      if abs($0.score - $1.score) > 0.001 { return $0.score > $1.score }
      if $0.hits != $1.hits { return $0.hits > $1.hits }
      if ($0.snack.kcalPack != nil) != ($1.snack.kcalPack != nil) { return $0.snack.kcalPack != nil }
      return $0.popularity > $1.popularity
    }
    // 同名の重複（JAN違い）をまとめる。
    // さらに、上位候補の名前に丸ごと含まれる短い名前（「ポテトチップス うすしお味」に対する「ポテトチップス」）は、
    // 長い方が全部読めている以上それより確からしくないので候補から外す
    var seen = Set<String>()
    var unique: [Scored] = []
    for s in scored where seen.insert(s.snack.nameNorm).inserted {
      let nb = TextNormalizer.bigrams(s.snack.nameNorm)
      let dominated = unique.contains { u in
        u.score >= s.score - 0.001 && nb.isSubset(of: TextNormalizer.bigrams(u.snack.nameNorm))
      }
      if !dominated { unique.append(s) }
    }

    guard let best = unique.first, best.score >= 0.5 else { return .none }
    let second = unique.dropFirst().first
    let sameCalories = second.map { $0.snack.calorieText == best.snack.calorieText } ?? false
    if best.score >= 0.75 && (second == nil || best.score - second!.score >= 0.12 || sameCalories) {
      return .confident(best.snack)
    }
    let options = unique.prefix(2).filter { $0.score >= 0.5 }.map(\.snack)
    return .ambiguous(options)
  }

  private struct Row { let snack: Snack; let popularity: Int; let brandNorm: String? }

  /// FTS5(trigram) で候補を絞る。FTS5 が使えない環境では LIKE にフォールバック
  private func candidates(for t: String) -> [Row] {
    let grams = TextNormalizer.trigrams(t)
    if isFTSAvailable && !grams.isEmpty {
      let match = grams.map { "\"\($0)\"" }.joined(separator: " OR ")
      let sql = """
        select \(Self.columns) from snacks_fts f join snacks s on s.rowid = f.rowid
        where snacks_fts match ?1 order by f.rank limit 80
        """
      if let rows = queryOrNil(sql, bind: [match]) { return rows }
      isFTSAvailable = false
      NSLog("[SnackAR] FTS5 が使えないため LIKE 検索に切り替えます")
    }
    // フォールバック：先頭数文字の部分一致
    let key = String(t.prefix(4))
    return query("select \(Self.columns) from snacks s where s.name_norm like ?1 limit 80", bind: ["%\(key)%"])
  }

  // MARK: - SQLite helpers

  private func query(_ sql: String, bind: [String]) -> [Row] {
    queryOrNil(sql, bind: bind) ?? []
  }

  private func queryOrNil(_ sql: String, bind: [String]) -> [Row]? {
    guard let db else { return [] }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, v) in bind.enumerated() {
      sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient)
    }
    var rows: [Row] = []
    while true {
      let rc = sqlite3_step(stmt)
      if rc == SQLITE_DONE { break }
      if rc != SQLITE_ROW { return rows.isEmpty ? nil : rows }
      let snack = Snack(
        code: text(stmt, 0) ?? "",
        nameJa: text(stmt, 1) ?? "",
        brand: text(stmt, 2),
        packG: double(stmt, 3),
        kcal100g: double(stmt, 4),
        kcalServing: double(stmt, 5),
        kcalPack: double(stmt, 6).map { Int($0.rounded()) },
        needsReview: sqlite3_column_int(stmt, 7) != 0,
        nameNorm: text(stmt, 8) ?? "",
        flavors: (text(stmt, 9) ?? "").split(separator: " ").map(String.init)
      )
      rows.append(Row(snack: snack, popularity: Int(sqlite3_column_int(stmt, 10)), brandNorm: text(stmt, 11)))
    }
    return rows
  }

  private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
    guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
    return String(cString: c)
  }

  private func double(_ stmt: OpaquePointer?, _ i: Int32) -> Double? {
    sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
  }
}
