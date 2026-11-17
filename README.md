# おかしカロリーAR

お菓子の棚にカメラを向けると、各商品の上に「1袋 158kcal」がARで浮かぶ iOS アプリ。
起動するとすぐカメラが開き、AR 以外の機能はありません。

## 構成

```
data/build_snacks.py            ① food.parquet → snacks.sqlite（PC側）
modules/snack-ar/ios/           ② iOS ネイティブ本体（Expo ローカルモジュール）
  SnackARView.swift               カメラ(ARKit) / 解析サイクル / トラッキング / ARラベル配置
  FrameAnalyzer.swift             ①検出（YOLO があれば YOLO、無ければ文字領域クラスタ）＋②Vision 文字認識
  SnackDatabase.swift             ③照合（FTS5 trigram で候補 → bigram 被覆率で採点 → 味名フィルタ）
  NutritionLabel.swift            裏面の栄養成分表示の読み取り＋仮登録（端末内 JSON）
  SnackLabelView.swift            ④ラベル表示（kcal / 候補タップ / 読み取り中 / 裏面）
  TextNormalizer.swift            正規化（Python 側と同じ規則）
  Resources/snacks.sqlite         同梱 DB
src/app/index.tsx               全画面 <SnackARView /> だけ
```

## ① データの準備

```bash
python3 -m venv .venv && .venv/bin/pip install duckdb
.venv/bin/python data/build_snacks.py ~/Downloads/food.parquet   # → modules/snack-ar/ios/Resources/snacks.sqlite
```

- 日本で販売 ∧（お菓子系カテゴリ ∨ 商品名のお菓子キーワード ∨ 製菓メーカー）、主食・飲料などは除外
- 日本語名 または JAN が 45/49 の商品に限定
- 1袋kcal = kcal/100g × 内容量（内容量は product_quantity → quantity → 商品名の「60g」の順）
- `needs_review=1`：kcal/100g が 250 未満・650 超、kJ の誤入力を補正したもの、1食分の値の不整合 → ラベルに「要確認」
- `snacks`（Open Food Facts 由来）と `user_snacks`（自前収集）はテーブルを分けている
- 商品名の正規化列 `name_norm` に FTS5（trigram）索引

## ② 実行（iPhone 実機が必要。ARKit はシミュレータで動きません）

```bash
npx expo run:ios --device
```

開発ビルドでは検出領域がピンクの枠で表示されます（`debug={__DEV__}`）。

### 処理の流れ（0.25秒ごと）
1. `VNDetectTextRectanglesRequest` で文字の枠 → 近い枠をまとめて「商品」領域にする（`SnackDetector.mlmodelc` を `Resources/` に置けば YOLO に切替）
2. JAN バーコードが見えればそれで完全一致
3. 前回の枠と IoU で対応付け。**当たった商品は再読み取りしない**。ワールド座標に固定してカメラを動かしてもラベルが追従
4. 未確定の領域だけ、大きい順に 2 つまで `VNRecognizeTextRequest`（ja-JP, accurate, ROI 指定）
5. 照合 → 確定ならラベル、僅差なら「候補 A / B」をタップで選択
6. 3回読めない →「文字が見えるように向けてください」、6回 →「裏面の栄養成分表示を見せてください」
7. 裏面が読めたら kcal を表示し、`Documents/pending_back_labels.json` に仮登録

## ③ 次の段階（未実装）
- 仮登録をサーバー（Supabase）へ送信 → 複数人一致で確定 → `user_snacks` に差分配信
- 棚の写真で「お菓子」1クラスの YOLO を学習 → Core ML 変換 → `Resources/SnackDetector.mlmodelc`
