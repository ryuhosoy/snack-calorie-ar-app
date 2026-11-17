import ARKit
import ExpoModulesCore
import SceneKit
import UIKit
import Vision

/// 画面に出た商品1つ分の追跡状態
final class Track {
  enum State {
    case reading
    case identified(Snack)
    case ambiguous([Snack])
    case backLabel(NutritionLabel)
  }

  let id = UUID()
  var viewRect: CGRect
  var visionRect: CGRect
  var lastSeen: CFTimeInterval
  var lastRead: CFTimeInterval = 0
  var attempts = 0
  var state: State = .reading
  var barcode: String?
  /// 商品の位置（ワールド座標）。決まればカメラを動かしてもラベルがその場に留まる
  var worldPosition: simd_float3?

  init(viewRect: CGRect, visionRect: CGRect, now: CFTimeInterval) {
    self.viewRect = viewRect
    self.visionRect = visionRect
    self.lastSeen = now
  }

  /// 一度当たった商品はもう読まない
  var needsReading: Bool {
    switch state {
    case .reading: return attempts < 12
    case .ambiguous: return attempts < 6
    case .identified, .backLabel: return false
    }
  }

  var isResolved: Bool {
    switch state {
    case .identified, .backLabel: return true
    default: return false
    }
  }
}

/// カメラ → 検出 → 文字認識 → 照合 → ARラベル表示 をすべて行う全画面ビュー
final class SnackARView: ExpoView {
  private let sceneView = ARSCNView()
  private let overlay = UIView()
  private let debugLayer = CAShapeLayer()
  private let hintLabel = PaddingLabel()
  private let analyzer = FrameAnalyzer()
  private let database = SnackDatabase.shared
  private let visionQueue = DispatchQueue(label: "snackar.vision", qos: .userInitiated)

  private var displayLink: CADisplayLink?
  private var isProcessing = false
  private var lastCycle: CFTimeInterval = 0
  private var lastAnyRegion: CFTimeInterval = CACurrentMediaTime()
  private var tracks: [Track] = []
  private var labels: [UUID: SnackLabelView] = [:]
  private var running = false

  /// Vision に渡す向き（縦持ちの背面カメラ）
  private let orientation: CGImagePropertyOrientation = .right
  private let cycleInterval: CFTimeInterval = 0.25
  private let maxReadsPerCycle = 2

  var debug = false {
    didSet { debugLayer.isHidden = !debug }
  }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    backgroundColor = .black

    sceneView.automaticallyUpdatesLighting = false
    sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(sceneView)

    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlay.backgroundColor = .clear
    addSubview(overlay)

    debugLayer.strokeColor = UIColor.systemPink.cgColor
    debugLayer.fillColor = UIColor.clear.cgColor
    debugLayer.lineWidth = 1.5
    debugLayer.isHidden = true
    overlay.layer.addSublayer(debugLayer)

    hintLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    hintLabel.textColor = .white
    hintLabel.numberOfLines = 0
    hintLabel.textAlignment = .center
    hintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    hintLabel.layer.cornerRadius = 14
    hintLabel.clipsToBounds = true
    hintLabel.alpha = 0
    addSubview(hintLabel)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    sceneView.frame = bounds
    overlay.frame = bounds
    debugLayer.frame = overlay.bounds
    layoutHint()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { start() } else { stop() }
  }

  deinit { displayLink?.invalidate() }

  // MARK: - ライフサイクル

  private func start() {
    guard !running else { return }
    guard ARWorldTrackingConfiguration.isSupported else {
      setHint("このアプリは ARKit 対応の iPhone 実機で動作します")
      return
    }
    running = true
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = [.horizontal, .vertical]
    config.isAutoFocusEnabled = true
    // 文字を読みやすくするため、なるべく高解像度の映像を使う
    if let best = ARWorldTrackingConfiguration.supportedVideoFormats
      .filter({ $0.framesPerSecond >= 30 })
      .max(by: { $0.imageResolution.width < $1.imageResolution.width }),
       best.imageResolution.width <= 3840 {
      config.videoFormat = best
    }
    sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

    let link = CADisplayLink(target: WeakProxy(self), selector: #selector(WeakProxy.tick))
    link.add(to: .main, forMode: .common)
    displayLink = link
    setHint("お菓子の棚にカメラを向けてください")
  }

  private func stop() {
    guard running else { return }
    running = false
    displayLink?.invalidate()
    displayLink = nil
    sceneView.session.pause()
  }

  // MARK: - 毎フレーム（メインスレッド）

  fileprivate func onDisplayLink() {
    guard let frame = sceneView.session.currentFrame else { return }
    let now = CACurrentMediaTime()
    renderLabels(frame: frame, now: now)

    guard !isProcessing, now - lastCycle >= cycleInterval else { return }
    if case .notAvailable = frame.camera.trackingState { return }
    lastCycle = now
    isProcessing = true
    startCycle(frame: frame, now: now)
  }

  // MARK: - 解析サイクル：検出(bg) → 対応付け(main) → 文字認識(bg) → 照合・反映(main)

  private func startCycle(frame: ARFrame, now: CFTimeInterval) {
    let pixelBuffer = frame.capturedImage
    let viewport = bounds.size
    let displayTransform = frame.displayTransform(for: .portrait, viewportSize: viewport)
    let camera = frame.camera
    let orientation = orientation

    visionQueue.async { [weak self] in
      guard let self else { return }
      let (regions, barcodes) = self.analyzer.detect(pixelBuffer: pixelBuffer, orientation: orientation)
      DispatchQueue.main.async {
        let toRead = self.associate(regions: regions, barcodes: barcodes, camera: camera,
                                    displayTransform: displayTransform, viewport: viewport, now: now)
        guard !toRead.isEmpty else {
          self.isProcessing = false
          return
        }
        let jobs = toRead.map { ($0.id, $0.visionRect) }
        self.visionQueue.async {
          let results = jobs.map { id, rect in
            (id, self.analyzer.recognizeText(pixelBuffer: pixelBuffer, orientation: orientation, region: rect))
          }
          // 照合もバックグラウンドで（SQLite は内部でロック）
          let matched = results.map { id, texts -> (UUID, [String], NutritionLabel?, MatchResult) in
            if let back = NutritionLabelParser.parse(texts) { return (id, texts, back, .none) }
            return (id, texts, nil, self.database.match(texts: texts))
          }
          DispatchQueue.main.async {
            self.apply(matched, now: CACurrentMediaTime())
            self.isProcessing = false
          }
        }
      }
    }
  }

  /// 新しい検出結果を既存の Track に対応付ける（前のフレームの枠との対応付け）
  private func associate(regions: [DetectedRegion], barcodes: [DetectedBarcode], camera: ARCamera,
                         displayTransform: CGAffineTransform, viewport: CGSize, now: CFTimeInterval) -> [Track] {
    var regionRects = regions.map {
      (vision: $0.visionRect, view: Self.visionToView($0.visionRect, transform: displayTransform, viewport: viewport))
    }
    if debug { drawDebug(regionRects.map(\.view)) }
    if !regionRects.isEmpty { lastAnyRegion = now }

    // 予測位置：ワールド位置が分かっている Track はカメラの動きを反映して投影
    let predicted: [CGRect] = tracks.map { t in
      guard let wp = t.worldPosition, let c = project(wp, camera: camera, viewport: viewport) else { return t.viewRect }
      return CGRect(x: c.x - t.viewRect.width / 2, y: c.y - t.viewRect.height / 2,
                    width: t.viewRect.width, height: t.viewRect.height)
    }

    // 貪欲法：IoU（無ければ中心距離）が最も良い組から確定
    var pairs: [(score: CGFloat, ti: Int, ri: Int)] = []
    for (ti, p) in predicted.enumerated() {
      for (ri, r) in regionRects.enumerated() {
        let iou = Self.iou(p, r.view)
        let dist = hypot(p.midX - r.view.midX, p.midY - r.view.midY)
        let near = dist < max(p.width, p.height, r.view.width, r.view.height) * 0.5
        if iou > 0.15 || near { pairs.append((iou + (near ? 0.1 : 0), ti, ri)) }
      }
    }
    pairs.sort { $0.score > $1.score }
    var usedT = Set<Int>(), usedR = Set<Int>()
    for p in pairs where !usedT.contains(p.ti) && !usedR.contains(p.ri) {
      usedT.insert(p.ti); usedR.insert(p.ri)
      let t = tracks[p.ti]
      t.viewRect = regionRects[p.ri].view
      t.visionRect = regionRects[p.ri].vision
      t.lastSeen = now
    }
    for (ri, r) in regionRects.enumerated() where !usedR.contains(ri) {
      tracks.append(Track(viewRect: r.view, visionRect: r.vision, now: now))
    }

    // バーコードが見えたら JAN で完全一致（最も確実）
    for bc in barcodes {
      let view = Self.visionToView(bc.visionRect, transform: displayTransform, viewport: viewport)
      let center = CGPoint(x: view.midX, y: view.midY)
      let owner = tracks.first { $0.viewRect.insetBy(dx: -20, dy: -20).contains(center) }
        ?? {
          let expanded = bc.visionRect.insetBy(dx: -bc.visionRect.width, dy: -bc.visionRect.height * 2)
          let t = Track(viewRect: Self.visionToView(expanded, transform: displayTransform, viewport: viewport),
                        visionRect: expanded, now: now)
          tracks.append(t)
          regionRects.append((expanded, t.viewRect))
          return t
        }()
      owner.barcode = bc.payload
      owner.lastSeen = now
      if !owner.isResolved, let snack = database.lookup(code: bc.payload) {
        owner.state = .identified(snack)
      }
    }

    // 見えなくなった Track を片付ける
    tracks.removeAll { t in
      let unseen = now - t.lastSeen
      if t.worldPosition != nil, t.isResolved {
        let onScreen = project(t.worldPosition!, camera: camera, viewport: viewport)
          .map { CGRect(origin: .zero, size: viewport).contains($0) } ?? false
        return onScreen ? unseen > 4 : unseen > 60
      }
      if t.isResolved { return unseen > 2.5 }
      return unseen > 1.0
    }
    // 同じ商品が重複して当たったら1つにまとめる
    var seenCodes = Set<String>()
    tracks.removeAll { t in
      guard case .identified(let s) = t.state else { return false }
      return !seenCodes.insert(s.code).inserted
    }
    labels.keys.filter { id in !tracks.contains { $0.id == id } }.forEach { id in
      labels[id]?.removeFromSuperview()
      labels[id] = nil
    }

    placeAnchors()

    // 読むべき Track：未確定・最近読んでいない・大きい順
    return tracks
      .filter { $0.needsReading && now - $0.lastSeen < 0.3 && now - $0.lastRead > 0.4 }
      .sorted { $0.viewRect.width * $0.viewRect.height > $1.viewRect.width * $1.viewRect.height }
      .prefix(maxReadsPerCycle)
      .map { t in t.lastRead = now; return t }
  }

  private func apply(_ results: [(UUID, [String], NutritionLabel?, MatchResult)], now: CFTimeInterval) {
    for (id, texts, back, match) in results {
      guard let t = tracks.first(where: { $0.id == id }), t.needsReading else { continue }
      t.attempts += 1
      if let back {
        t.state = .backLabel(back)
        PendingStore.shared.add(label: back, barcode: t.barcode, texts: texts)
        continue
      }
      switch match {
      case .confident(let snack):
        t.state = .identified(snack)
      case .ambiguous(let options) where !options.isEmpty:
        t.state = .ambiguous(options)
      default:
        break
      }
    }
    placeAnchors()
  }

  /// 当たった商品の位置をワールド座標で固定する（ARのレイキャスト）
  private func placeAnchors() {
    for t in tracks where t.isResolved && t.worldPosition == nil {
      let center = CGPoint(x: t.viewRect.midX, y: t.viewRect.midY)
      guard let q = sceneView.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .any),
            let hit = sceneView.session.raycast(q).first else { continue }
      let c = hit.worldTransform.columns.3
      t.worldPosition = simd_float3(c.x, c.y, c.z)
      sceneView.session.add(anchor: ARAnchor(name: "snack-\(t.id.uuidString)", transform: hit.worldTransform))
    }
  }

  // MARK: - 描画

  private func renderLabels(frame: ARFrame, now: CFTimeInterval) {
    let viewport = bounds.size
    var bestUnresolved: Track?

    for t in tracks {
      var rect = t.viewRect
      if let wp = t.worldPosition {
        guard let c = project(wp, camera: frame.camera, viewport: viewport) else {
          labels[t.id]?.isHidden = true
          continue
        }
        rect = CGRect(x: c.x - rect.width / 2, y: c.y - rect.height / 2, width: rect.width, height: rect.height)
      }

      let label = labels[t.id] ?? makeLabel(for: t)
      switch t.state {
      case .identified(let s):
        label.showIdentified(s)
      case .ambiguous(let options):
        label.showChoices(options)
      case .backLabel(let back):
        label.showBackLabel(back)
      case .reading:
        // 小さい文字のかたまり（値札など）には出さない
        let big = rect.width * rect.height > viewport.width * viewport.height * 0.02
        if !big || now - t.lastSeen > 0.5 {
          label.isHidden = true
          continue
        }
        label.showReading(hint: t.attempts >= 3 ? "文字が見えるように…" : "読み取り中…")
        if bestUnresolved == nil || t.attempts > bestUnresolved!.attempts { bestUnresolved = t }
      }

      let size = label.fittingSize(maxWidth: min(260, viewport.width - 24))
      var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6)
      if origin.y < safeAreaInsets.top + 4 { origin.y = rect.minY + 6 }  // 上にはみ出すなら枠の内側へ
      origin.x = max(8, min(origin.x, viewport.width - size.width - 8))
      label.frame = CGRect(origin: origin, size: size)
      label.isHidden = false
    }

    // 画面下のガイド
    if tracks.isEmpty && now - lastAnyRegion > 1.5 {
      setHint("お菓子の棚にカメラを向けてください")
    } else if let t = bestUnresolved, t.attempts >= 6 {
      setHint("見つかりません。裏面の「栄養成分表示」を見せてください")
    } else if let t = bestUnresolved, t.attempts >= 3 {
      setHint("文字が見えるように向けてください")
    } else {
      setHint(nil)
    }
  }

  private func makeLabel(for t: Track) -> SnackLabelView {
    let v = SnackLabelView()
    v.onChoose = { [weak self, weak t] snack in
      guard let self, let t else { return }
      t.state = .identified(snack)
      self.placeAnchors()
    }
    overlay.addSubview(v)
    labels[t.id] = v
    return v
  }

  private func drawDebug(_ rects: [CGRect]) {
    let path = UIBezierPath()
    rects.forEach { path.append(UIBezierPath(rect: $0)) }
    debugLayer.path = path.cgPath
  }

  private func setHint(_ text: String?) {
    if hintLabel.text != text, let text { hintLabel.text = text; layoutHint() }
    let alpha: CGFloat = text == nil ? 0 : 1
    if hintLabel.alpha != alpha {
      UIView.animate(withDuration: 0.25) { self.hintLabel.alpha = alpha }
    }
  }

  private func layoutHint() {
    let maxW = bounds.width - 48
    let s = hintLabel.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude))
    let w = min(maxW, s.width)
    hintLabel.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - safeAreaInsets.bottom - s.height - 32,
                             width: w, height: s.height)
  }

  // MARK: - 座標変換

  /// Vision の矩形（向き補正後・左下原点の正規化座標）→ 画面の座標
  static func visionToView(_ r: CGRect, transform: CGAffineTransform, viewport: CGSize) -> CGRect {
    let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                   CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    let pts = corners.map { p -> CGPoint in
      // 縦向き画像（左上原点）→ カメラの生画像（横向き・左上原点）。orientation .right の逆変換
      let xo = p.x, yo = 1 - p.y
      let raw = CGPoint(x: yo, y: 1 - xo)
      let n = raw.applying(transform)
      return CGPoint(x: n.x * viewport.width, y: n.y * viewport.height)
    }
    let xs = pts.map(\.x), ys = pts.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }

  private func project(_ p: simd_float3, camera: ARCamera, viewport: CGSize) -> CGPoint? {
    // カメラの後ろにある点は描かない
    let local = simd_mul(simd_inverse(camera.transform), simd_float4(p, 1))
    guard local.z < 0 else { return nil }
    return camera.projectPoint(p, orientation: .portrait, viewportSize: viewport)
  }

  static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let inter = i.width * i.height
    return inter / (a.width * a.height + b.width * b.height - inter)
  }
}

/// CADisplayLink がビューを強参照しないための中継
private final class WeakProxy: NSObject {
  weak var target: SnackARView?
  init(_ target: SnackARView) { self.target = target }
  @objc func tick() { target?.onDisplayLink() }
}

final class PaddingLabel: UILabel {
  var insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
  override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let s = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
    return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
  }
}
