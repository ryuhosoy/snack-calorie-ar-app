"""
food.parquet (Open Food Facts) -> snacks.sqlite

使い方:
  python build_snacks.py /path/to/food.parquet ../modules/snack-ar/ios/Resources/snacks.sqlite

手順:
  1. DuckDB で「日本で販売」かつ「お菓子系」の商品を抽出
  2. 1袋あたりkcalを計算し、異常値に needs_review=1 を付ける
  3. SQLite に書き出し、正規化した商品名に FTS5(trigram) 索引を張る
"""
import re
import sqlite3
import sys
import unicodedata
from pathlib import Path

import duckdb

SRC = sys.argv[1] if len(sys.argv) > 1 else "/Users/ryuhosoy/Downloads/food.parquet"
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else Path(__file__).parent.parent / "modules/snack-ar/ios/Resources/snacks.sqlite")

SNACK_CATEGORIES = [
    "en:snacks", "en:sweet-snacks", "en:salty-snacks", "en:confectioneries", "en:biscuits-and-cakes",
    "en:biscuits", "en:biscuits-and-crackers", "en:crackers", "en:cakes", "en:chocolates",
    "en:chocolate-candies", "en:candies", "en:chips-and-fries", "en:crisps", "en:potato-crisps",
    "en:gummies", "en:chewing-gum", "en:rice-crackers", "en:bars",
    "en:cookies", "en:wafers", "en:popcorn", "en:pastries", "en:nuts", "en:salted-nuts",
    "ja:スナック菓子", "ja:お菓子", "ja:菓子", "ja:米菓", "ja:せんべい", "ja:チョコレート",
]

# 商品名にこれが入っていればお菓子とみなす
SNACK_WORDS = [
    "チョコ", "ポテト", "チップス", "スナック", "クッキー", "ビスケット", "クラッカー", "せんべい", "煎餅",
    "おかき", "あられ", "柿の種", "柿ピー", "ガム", "グミ", "キャンディ", "キャンデー", "飴", "あめ",
    "ポッキー", "プリッツ", "トッポ", "コアラのマーチ", "きのこの山", "たけのこの里", "じゃがりこ",
    "じゃがビー", "カール", "ハッピーターン", "ばかうけ", "うまい棒", "ポテコ", "ピザポテト", "かっぱえびせん",
    "ウエハース", "ワッフル", "マシュマロ", "ラムネ", "キャラメル", "ドーナツ", "バウムクーヘン",
    "パイ", "ケーキ", "マドレーヌ", "フィナンシェ", "サブレ", "ラスク", "プレッツェル", "ポップコーン",
    "ナッツ", "ピーナッツ", "アーモンド", "カシューナッツ", "かりんとう", "まんじゅう", "饅頭", "羊羹",
    "ようかん", "大福", "どら焼", "団子", "だんご", "最中", "もなか", "おこし", "ボーロ", "クランチ",
    "トリュフ", "タブレット", "ミンツ", "フリスク", "コーン", "ハイチュウ", "ぷっちょ", "ブラックサンダー",
    "アルフォート", "カントリーマアム", "ルマンド", "ブルボン", "コロン", "パンダ", "ベビースター",
    "ドリトス", "チートス", "プリングルズ", "わさビーフ", "堅あげ", "暴君ハバネロ", "歌舞伎揚",
    "雪の宿", "ぽたぽた焼", "サラダせん", "揚げせん", "小枝", "ダース", "アポロ", "ガルボ", "メルティーキッス",
    "キットカット", "KitKat", "Pocky", "Pretz", "チョコパイ", "源氏パイ", "ムーンライト", "マリー",
    "ハーベスト", "ビスコ", "ジャガビー", "チップスター", "オーザック", "スコーン", "ドンタコス", "ポリンキー",
    "ハイレモン", "ミルキー", "サクマ", "カルミン", "キシリトール", "フルーツバー", "ミルクチョコ",
]

SNACK_BRANDS = [
    "カルビー", "calbee", "湖池屋", "koikeya", "明治", "meiji", "グリコ", "glico", "江崎グリコ", "ロッテ", "lotte",
    "森永", "morinaga", "ブルボン", "bourbon", "亀田製菓", "kameda", "不二家", "fujiya", "東ハト", "tohato",
    "ヤマザキビスケット", "やおきん", "おやつカンパニー", "uha味覚糖", "カバヤ", "kabaya", "春日井", "でん六",
    "岩塚製菓", "三幸製菓", "有楽製菓", "チロル", "ネスレ", "nestle", "ギンビス", "前田製菓", "北日本食品",
    "ヤマヨシ", "山芳", "フルタ", "ノーベル", "扇雀飴", "クラシエ", "kracie", "ハリボー", "haribo",
]

# お菓子っぽい単語を含んでも除外する（飲料・主食・調味料など）
EXCLUDE_WORDS = [
    "ドリンク", "飲料", "ジュース", "牛乳", "ミルクティー", "コーヒー", "珈琲", "ラテ", "カフェオレ", "茶",
    "水", "ソーダ", "サイダー", "ビール", "酒", "ワイン", "弁当", "おにぎり", "ごはん", "ご飯", "パスタ",
    "ラーメン", "うどん", "そば", "焼そば", "カレー", "シチュー", "スープ", "ドレッシング", "ソース", "たれ",
    "タレ", "マヨネーズ", "醤油", "味噌", "みそ", "豆腐", "納豆", "ヨーグルト", "シリアル", "フレーク",
    "グラノーラ", "食パン", "サンドイッチ", "サンド イッチ", "ハム", "ソーセージ", "ベーコン", "鶏", "牛", "豚",
    "魚", "まぐろ", "サーモン", "寿司", "冷凍", "アイス", "サプリ", "プロテインパウダー", "粉末", "ふりかけ",
]
# "茶" の除外は抹茶・ほうじ茶味のお菓子を消してしまうので、お菓子語と一緒なら残す
EXCLUDE_UNLESS_SNACK = {"茶", "牛", "鶏", "コーン", "水"}

# 味名（候補の商品名に入っているのに、読めた文字に無ければ除外する）
FLAVOR_WORDS = [
    "いちご", "苺", "ストロベリー", "抹茶", "ほうじ茶", "チョコ", "ホワイト", "ビター", "ミルク", "バニラ",
    "キャラメル", "塩", "うすしお", "のり塩", "コンソメ", "バター", "しょうゆ", "醤油", "チーズ", "わさび",
    "カレー", "めんたい", "明太", "梅", "レモン", "メロン", "バナナ", "ぶどう", "グレープ", "マスカット",
    "ピーチ", "もも", "りんご", "アップル", "オレンジ", "みかん", "マンゴー", "ソーダ", "コーラ", "ヨーグルト",
    "サラダ", "えび", "海老", "ガーリック", "ペッパー", "ブラックペッパー", "BBQ", "バーベキュー", "サワークリーム",
    "トマト", "ピザ", "たこ焼", "やきとり", "焼肉", "麻辣", "辛", "激辛", "ハバネロ", "黒糖", "きなこ",
    "あずき", "小豆", "ごま", "胡麻", "アーモンド", "マカダミア", "ピーナッツ", "ココナッツ", "紅茶", "コーヒー",
    "ラムレーズン", "クッキー&クリーム", "ハニー", "はちみつ", "蜂蜜", "シナモン", "さつまいも", "紫いも", "栗", "マロン",
]


def normalize(s: str) -> str:
    """アプリ側 (Swift) の normalize と同じ処理: NFKC → 小文字 → カタカナ→ひらがな → 空白・記号除去"""
    if not s:
        return ""
    s = unicodedata.normalize("NFKC", s).lower()
    out = []
    for ch in s:
        o = ord(ch)
        if 0x30A1 <= o <= 0x30F6:  # カタカナ → ひらがな
            ch = chr(o - 0x60)
        if ch.isalnum() or ch == "ー" or 0x3040 <= ord(ch) <= 0x30FF or 0x4E00 <= ord(ch) <= 0x9FFF:
            out.append(ch)
    return "".join(out)


def grams(text):
    """'164g' '2 x 30.8g' '55 g' '1袋(55g)' → グラム数"""
    if not text:
        return None
    t = unicodedata.normalize("NFKC", str(text)).lower().replace(" ", "")
    m = re.search(r"(\d+)[x×](\d+(?:\.\d+)?)g", t)
    if m:
        return float(m.group(1)) * float(m.group(2))
    m = re.search(r"(\d+(?:\.\d+)?)(g|グラム)(?![a-z])", t)
    if m:
        return float(m.group(1))
    return None


def main():
    con = duckdb.connect()
    cats = ", ".join(f"'{c}'" for c in SNACK_CATEGORIES)
    print("DuckDB: 日本の商品を抽出中…")
    rows = con.sql(f"""
        with j as (
          select code,
                 coalesce(list_filter(product_name, lambda x: x.lang='ja')[1].text,
                          list_filter(product_name, lambda x: x.lang='main')[1].text) as name_ja,
                 list_filter(product_name, lambda x: x.lang='en')[1].text as name_en,
                 brands, quantity, product_quantity, product_quantity_unit,
                 serving_size, serving_quantity, nutrition_data_per,
                 list_filter(nutriments, lambda x: x.name='energy-kcal')[1] as kc,
                 list_filter(nutriments, lambda x: x.name='energy')[1] as kj,
                 list_has_any(categories_tags, [{cats}]) as is_snack_cat,
                 coalesce(unique_scans_n, 0) as scans
          from read_parquet('{SRC}')
          where list_contains(countries_tags, 'en:japan') and coalesce(obsolete, false) = false
        )
        select code, name_ja, name_en, brands, quantity, product_quantity, product_quantity_unit,
               serving_size, serving_quantity, nutrition_data_per,
               kc."100g", kc.serving, kj."100g", is_snack_cat, scans
        from j
        where name_ja is not null and length(trim(name_ja)) > 1
    """).fetchall()
    print(f"  日本の商品（名前あり）: {len(rows)}")

    snack_words_n = [normalize(w) for w in SNACK_WORDS]
    brands_n = [normalize(b) for b in SNACK_BRANDS]
    excl_n = [(normalize(w), w in EXCLUDE_UNLESS_SNACK) for w in EXCLUDE_WORDS]
    flavors_n = sorted({normalize(f) for f in FLAVOR_WORDS}, key=len, reverse=True)

    out = []
    seen = set()
    for (code, name_ja, name_en, brands, quantity, pq, pqu, ssize, sq, per,
         k100, kserv, kj100, is_cat, scans) in rows:
        if code in seen:
            continue
        nn = normalize(name_ja)
        if len(nn) < 2:
            continue
        # 日本の棚にある商品に限定：日本語名を持つか、日本の JAN (45/49) のもの
        has_jp = re.search(r"[\u3040-\u30ff\u4e00-\u9fff]", name_ja) is not None
        if not has_jp and not str(code).startswith(("45", "49")):
            continue
        bn = normalize(brands or "")
        word_hit = any(w in nn for w in snack_words_n)
        brand_hit = any(b and b in bn for b in brands_n)
        if not (is_cat or word_hit or brand_hit):
            continue
        excluded = False
        for w, soft in excl_n:
            if w and w in nn and not (soft and word_hit):
                excluded = True
                break
        if excluded and not is_cat:
            continue

        # kcal/100g（kJ しか無い場合は換算）
        kcal100 = k100
        if (kcal100 is None or kcal100 <= 0) and kj100:
            kcal100 = kj100 / 4.184
        if kcal100 is not None and kcal100 <= 0:
            kcal100 = None
        kj_fixed = False
        if kcal100 and kcal100 > 900:  # kJ を kcal 欄に入れた誤入力（脂質100%でも900kcal）
            kcal100 = kcal100 / 4.184
            kj_fixed = True

        pack_g = None
        if pq and (pqu or "g").lower() == "g":
            try:
                pack_g = float(pq)
            except ValueError:
                pack_g = None
        if not pack_g:
            pack_g = grams(quantity)
        if not pack_g:
            pack_g = grams(name_ja)  # 「うすしお味 60g」のように商品名に内容量があることが多い

        serving_g = None
        try:
            serving_g = float(sq) if sq else None
        except ValueError:
            pass
        if not serving_g:
            serving_g = grams(ssize)

        kcal_serving = kserv if kserv and kserv > 0 else None
        if kcal_serving is None and kcal100 and serving_g:
            kcal_serving = kcal100 * serving_g / 100

        # 1袋あたり
        kcal_pack = None
        pack_source = None
        if kcal100 and pack_g:
            kcal_pack = kcal100 * pack_g / 100
            pack_source = "quantity"
        elif kcal_serving and ssize and re.search(r"1\s*(袋|箱|個|本|枚|パック)", unicodedata.normalize("NFKC", ssize)):
            kcal_pack = kcal_serving
            pack_source = "serving"
        elif kcal_serving and per == "serving" and serving_g and kcal100 is None:
            kcal_pack = kcal_serving
            pack_source = "serving"

        if not (kcal100 or kcal_pack or kcal_serving):
            continue
        # メーカー名だけで拾った低カロリー品は飲料・乳製品の可能性が高いので除外
        if not is_cat and not word_hit and (kcal100 is None or kcal100 < 150):
            continue

        reasons = ["kj_as_kcal"] if kj_fixed else []
        if kcal100 is not None:
            if kcal100 < 250:
                reasons.append("kcal100<250")
            if kcal100 > 650:
                reasons.append("kcal100>650")
        if kcal_pack is not None and (kcal_pack < 5 or kcal_pack > 2500):
            reasons.append("pack_out_of_range")
        if kcal100 and kcal_serving and serving_g:
            expected = kcal100 * serving_g / 100
            if expected > 0 and abs(expected - kcal_serving) / expected > 0.25:
                reasons.append("serving_mismatch")

        flavors = [f for f in flavors_n if f in nn]
        # 長い味名に含まれる短い味名は重複させない（"のりしお" に対する "しお" など）
        flavors = [f for f in flavors if not any(f != g and f in g for g in flavors)]

        seen.add(code)
        out.append(dict(
            code=code, name_ja=name_ja.strip(), name_en=(name_en or "").strip() or None,
            brand=(brands or "").split(",")[0].strip() or None, brands=brands,
            quantity=quantity, pack_g=pack_g, serving_size=ssize, serving_g=serving_g,
            kcal_100g=round(kcal100, 1) if kcal100 else None,
            kcal_serving=round(kcal_serving, 1) if kcal_serving else None,
            kcal_pack=round(kcal_pack) if kcal_pack else None, pack_source=pack_source,
            needs_review=1 if reasons else 0, review_reasons=",".join(reasons) or None,
            name_norm=nn, brand_norm=bn, flavors=" ".join(flavors), popularity=scans or 0,
        ))

    print(f"  お菓子として採用: {len(out)}  (要確認 {sum(r['needs_review'] for r in out)})")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    if OUT.exists():
        OUT.unlink()
    db = sqlite3.connect(OUT)
    db.executescript("""
        create table meta (key text primary key, value text);
        -- Open Food Facts 由来（読み取り専用）。ユーザー収集データは別テーブル user_snacks で管理する
        create table snacks (
          code text primary key, name_ja text not null, name_en text, brand text, brands text,
          quantity text, pack_g real, serving_size text, serving_g real,
          kcal_100g real, kcal_serving real, kcal_pack integer, pack_source text,
          needs_review integer not null default 0, review_reasons text,
          name_norm text not null, brand_norm text, flavors text, popularity integer default 0,
          source text not null default 'off'
        );
        create table user_snacks (
          code text primary key, name_ja text not null, brand text, pack_g real,
          kcal_100g real, kcal_pack integer, name_norm text not null, flavors text,
          status text not null default 'confirmed', updated_at integer
        );
        create virtual table snacks_fts using fts5(name_norm, brand_norm, content='snacks', content_rowid='rowid', tokenize='trigram');
    """)
    cols = list(out[0].keys())
    db.executemany(
        f"insert into snacks ({','.join(cols)}) values ({','.join('?' * len(cols))})",
        [tuple(r[c] for c in cols) for r in out],
    )
    db.execute("insert into snacks_fts(rowid, name_norm, brand_norm) select rowid, name_norm, coalesce(brand_norm,'') from snacks")
    db.execute("insert into snacks_fts(snacks_fts) values('optimize')")
    db.executemany("insert into meta values (?,?)", [
        ("source", "Open Food Facts (ODbL)"),
        ("version", "1"),
        ("count", str(len(out))),
    ])
    db.commit()
    db.execute("vacuum")
    db.close()
    print(f"書き出し: {OUT} ({OUT.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
