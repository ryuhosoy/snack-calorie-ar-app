import UIKit

/// 商品の上に浮かべるラベル。「1袋 158kcal」/ 候補選択 / 読み取り中 / 裏面読取
final class SnackLabelView: UIView {
  var onChoose: ((Snack) -> Void)?

  private let stack = UIStackView()
  private let kcalLabel = UILabel()
  private let nameLabel = UILabel()
  private let badge = UILabel()
  private var choiceButtons: [UIButton] = []
  private var choices: [Snack] = []
  private var renderedKey = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor.black.withAlphaComponent(0.72)
    layer.cornerRadius = 12
    layer.borderWidth = 1
    layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.35
    layer.shadowRadius = 6
    layer.shadowOffset = .zero

    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 3
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
    ])

    kcalLabel.font = .systemFont(ofSize: 20, weight: .heavy)
    kcalLabel.textColor = .white
    kcalLabel.adjustsFontSizeToFitWidth = true
    kcalLabel.minimumScaleFactor = 0.6
    nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
    nameLabel.textColor = UIColor.white.withAlphaComponent(0.85)
    nameLabel.lineBreakMode = .byTruncatingTail
    badge.font = .systemFont(ofSize: 10, weight: .bold)
    badge.textColor = .black
    badge.backgroundColor = .systemYellow
    badge.layer.cornerRadius = 4
    badge.clipsToBounds = true
    badge.textAlignment = .center

    [kcalLabel, nameLabel, badge].forEach(stack.addArrangedSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  func showIdentified(_ snack: Snack) {
    let key = "id:\(snack.code)"
    guard key != renderedKey else { return }
    renderedKey = key
    clearChoices()
    kcalLabel.isHidden = false
    kcalLabel.text = snack.calorieText
    kcalLabel.textColor = .white
    nameLabel.isHidden = false
    nameLabel.text = snack.nameJa
    badge.isHidden = !snack.needsReview
    badge.text = " 要確認 "
    layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.8).cgColor
  }

  func showChoices(_ snacks: [Snack]) {
    let key = "amb:" + snacks.map(\.code).joined(separator: ",")
    guard key != renderedKey else { return }
    renderedKey = key
    clearChoices()
    kcalLabel.isHidden = true
    nameLabel.isHidden = false
    nameLabel.text = snacks.count > 1 ? "候補をタップ" : "これですか？"
    badge.isHidden = true
    layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.9).cgColor
    choices = snacks
    for (i, s) in snacks.enumerated() {
      var conf = UIButton.Configuration.filled()
      conf.baseBackgroundColor = UIColor.white.withAlphaComponent(0.18)
      conf.baseForegroundColor = .white
      conf.cornerStyle = .medium
      conf.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
      var title = AttributedString("\(s.nameJa.prefix(14))  \(s.calorieText)")
      title.font = .systemFont(ofSize: 12, weight: .semibold)
      conf.attributedTitle = title
      let b = UIButton(configuration: conf)
      b.tag = i
      b.addTarget(self, action: #selector(tapChoice(_:)), for: .touchUpInside)
      choiceButtons.append(b)
      stack.addArrangedSubview(b)
    }
  }

  func showReading(hint: String) {
    let key = "read:\(hint)"
    guard key != renderedKey else { return }
    renderedKey = key
    clearChoices()
    kcalLabel.isHidden = true
    nameLabel.isHidden = false
    nameLabel.text = hint
    badge.isHidden = true
    layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
  }

  func showBackLabel(_ label: NutritionLabel) {
    let key = "back:\(label.displayText)"
    guard key != renderedKey else { return }
    renderedKey = key
    clearChoices()
    kcalLabel.isHidden = false
    kcalLabel.text = label.displayText
    kcalLabel.textColor = .white
    nameLabel.isHidden = false
    nameLabel.text = "裏面から読み取り（仮登録）"
    badge.isHidden = true
    layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.9).cgColor
  }

  private func clearChoices() {
    choiceButtons.forEach { $0.removeFromSuperview() }
    choiceButtons = []
    choices = []
  }

  @objc private func tapChoice(_ sender: UIButton) {
    guard choices.indices.contains(sender.tag) else { return }
    onChoose?(choices[sender.tag])
  }

  /// 自分の中身にちょうど合うサイズ（最大幅 maxWidth）
  func fittingSize(maxWidth: CGFloat) -> CGSize {
    let s = systemLayoutSizeFitting(
      CGSize(width: maxWidth, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .fittingSizeLevel,
      verticalFittingPriority: .fittingSizeLevel)
    return CGSize(width: min(max(s.width, 80), maxWidth), height: s.height)
  }
}
