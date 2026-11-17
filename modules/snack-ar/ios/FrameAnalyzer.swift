import CoreML
import Foundation
import Vision

/// 1フレーム分の検出結果（座標はすべて Vision の正規化座標：向き補正後・左下原点）
struct DetectedRegion {
  var visionRect: CGRect
}

struct DetectedBarcode {
  let payload: String
  let visionRect: CGRect
}

/// ① お菓子の袋・箱を検出 ② 枠の中の文字を読む を担当
final class FrameAnalyzer {
  /// 学習済みモデル（SnackDetector.mlmodelc）を同梱すれば YOLO 検出を使う。無ければ文字領域のかたまりで代用
  private let yolo: VNCoreMLModel?

  init() {
    yolo = Self.loadDetector()
    NSLog("[SnackAR] 検出方式: %@", yolo == nil ? "文字領域クラスタリング" : "YOLO (Core ML)")
  }

  private static func loadDetector() -> VNCoreMLModel? {
    let bundles = [Bundle.main] + [Bundle.main.url(forResource: "SnackARResources", withExtension: "bundle")]
      .compactMap { $0.flatMap(Bundle.init(url:)) }
    for b in bundles {
      if let url = b.url(forResource: "SnackDetector", withExtension: "mlmodelc"),
         let model = try? MLModel(contentsOf: url),
         let vn = try? VNCoreMLModel(for: model) {
        return vn
      }
    }
    return nil
  }

  // MARK: - ① 検出

  func detect(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)
    -> (regions: [DetectedRegion], barcodes: [DetectedBarcode]) {
    let barcodeReq = VNDetectBarcodesRequest()
    barcodeReq.symbologies = [.ean13, .ean8]

    var requests: [VNRequest] = [barcodeReq]
    let textReq = VNDetectTextRectanglesRequest()
    var yoloReq: VNCoreMLRequest?
    if let yolo {
      let r = VNCoreMLRequest(model: yolo)
      r.imageCropAndScaleOption = .scaleFill
      yoloReq = r
      requests.append(r)
    } else {
      requests.append(textReq)
    }

    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
    do { try handler.perform(requests) } catch { return ([], []) }

    let barcodes = (barcodeReq.results ?? []).compactMap { obs -> DetectedBarcode? in
      guard let p = obs.payloadStringValue, p.allSatisfy(\.isNumber) else { return nil }
      return DetectedBarcode(payload: p, visionRect: obs.boundingBox)
    }

    if let yoloReq {
      let boxes = (yoloReq.results as? [VNRecognizedObjectObservation] ?? [])
        .filter { $0.confidence > 0.4 }
        .map { DetectedRegion(visionRect: $0.boundingBox) }
      return (boxes, barcodes)
    }

    let textBoxes = (textReq.results ?? []).map(\.boundingBox).filter { $0.height > 0.012 }
    return (Self.cluster(textBoxes), barcodes)
  }

  /// 近くにある文字の枠を1つの「商品」とみなしてまとめる（YOLO を学習するまでの代用）
  static func cluster(_ boxes: [CGRect]) -> [DetectedRegion] {
    guard !boxes.isEmpty else { return [] }
    var parent = Array(0..<boxes.count)
    func find(_ i: Int) -> Int {
      var i = i
      while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
      return i
    }
    // 文字の高さに比例して広げ、重なったら同じ商品
    let expanded = boxes.map { b -> CGRect in
      let pad = min(b.height * 1.2, 0.06)
      return b.insetBy(dx: -pad * 0.75, dy: -pad)
    }
    for i in 0..<boxes.count {
      for j in (i + 1)..<boxes.count where expanded[i].intersects(expanded[j]) {
        parent[find(i)] = find(j)
      }
    }
    var groups: [Int: CGRect] = [:]
    var counts: [Int: Int] = [:]
    for i in 0..<boxes.count {
      let r = find(i)
      groups[r] = groups[r].map { $0.union(boxes[i]) } ?? boxes[i]
      counts[r, default: 0] += 1
    }
    return groups.compactMap { key, rect in
      // 値札などの小さな文字だけのかたまりは除く
      let area = rect.width * rect.height
      guard area > 0.002 || (counts[key] ?? 0) >= 3 else { return nil }
      return DetectedRegion(visionRect: rect)
    }
  }

  // MARK: - ② 文字認識（Apple Vision・端末内・日本語）

  func recognizeText(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, region: CGRect) -> [String] {
    var texts: [String] = []
    let req = VNRecognizeTextRequest { req, _ in
      texts = (req.results as? [VNRecognizedTextObservation])?
        .compactMap { $0.topCandidates(1).first?.string } ?? []
    }
    req.recognitionLanguages = ["ja-JP", "en-US"]
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false  // 商品名は辞書に無い語が多い
    let roi = region.insetBy(dx: -region.width * 0.08, dy: -region.height * 0.08)
      .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !roi.isNull, roi.width > 0.01, roi.height > 0.01 else { return [] }
    req.regionOfInterest = roi
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
    try? handler.perform([req])
    return texts
  }
}
