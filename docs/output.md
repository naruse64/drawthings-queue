# dtq の出力契約

**この文書は単体で完結している。** 生成システム（dtq）が何を、どこに、どの形式で
出力するかだけを書く。内部の作りには触れない。下流のツールはこれだけ読めばよい。

生成の仕組みそのものは [spec.md](spec.md)、設計判断の理由は
[findings.md](findings.md) にある。**下流のツールがそれらを読む必要はない。**

---

## 1. どこに何が出るか

```
~/Library/Mobile Documents/com~apple~CloudDocs/DrawThingsQueue/
├── results/<job_id>.result.json    成功した生成1件の記録
├── failed/<job_id>.error.json      失敗した生成1件の記録
└── thumbs/<画像名>.jpg              長辺512pxのJPEG

~/DrawThings/<主題>_<seed>_<日時>.png   画像の原本（既定。設定で変更可）
```

iCloud のルートは環境変数 `DTQ_ICLOUD_ROOT`、画像の保存先は `DTQ_IMAGES_DIR` で
変わりうる。**パスを決め打ちせず、`result.json` の値を使うこと。**

---

## 2. 完了の合図は `result.json` の出現

**`results/<job_id>.result.json` が現れたら、それが参照するファイルはすべて完成している。**

- 画像とサムネイルは `result.json` より先に書かれる
- `result.json` は一時ファイルに書いてから `mv` で置かれる（原子的）
- したがって**書き込み途中の JSON を読むことはない**

画像ファイル自体を監視する必要はない。`results/` だけ見ればよい。

---

## 3. `result.json`

```json
{
  "schema_version": 1,
  "job_id": "scene-txt-a1b2c3d4-1788223421-000",
  "source": "scene.txt",
  "title": "seaside",
  "prompt": "a seaside promenade. a woman in her twenties. 35mm film photograph.",
  "negative_prompt": "blurry, distorted, text",
  "seed": 555001,
  "steps": 8,
  "width": 832,
  "height": 1216,
  "batch": 1,
  "model": { "file": "example_base_model_f16.ckpt" },
  "loras": [{ "file": "example_style_lora_f16.ckpt", "weight": 0.6 }],
  "attempts": 1,
  "status": "success",
  "images": [
    {
      "path": "/Users/<name>/DrawThings/seaside_555001_20260901-094348.png",
      "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "thumb": "thumbs/seaside_555001_20260901-094348.jpg"
    }
  ],
  "started_at": "2026-09-01T09:43:48+09:00",
  "finished_at": "2026-09-01T09:45:14+09:00",
  "duration_sec": 86
}
```

| フィールド | 内容 |
|---|---|
| `schema_version` | このキー構成の版。未知の値なら消費側で警告できる |
| `job_id` | 一意。同じ入力を再投入しても別の値になる |
| `source` | 投入されたファイル名。1ファイルから複数ジョブが出る |
| `title` | 英数と `-` に正規化済み。画像ファイル名の先頭に使われる |
| `prompt` / `negative_prompt` | 実際に渡された文字列。`negative_prompt` は `null` のことがある |
| `seed` | 実際に使われた値。ランダム指定でも確定値が入る |
| `model` | 使用したベースモデル。`sampler` と `cfg_scale` は記録しない（後述） |
| `loras` | 空配列ではなく**キーごと無いことがある** |
| `attempts` | **生成を試みた回数。** `1` は初回成功、`2` は1回失敗して再試行で成功 |
| `status` | 成功時は常に `"success"` |
| `images` | **配列。`batch` が2以上なら複数要素**になる |
| `images[].path` | **絶対パス**。画像の原本 |
| `images[].sha256` | 画像の生バイトの SHA-256。**パスに依存しない同定に使える** |
| `images[].thumb` | **iCloud ルートからの相対パス**。`null` のことがある |
| `duration_sec` | 整数秒 |

**`path` は絶対、`thumb` は相対。** 揃っていないので注意。

**`sampler` と `cfg_scale` は記録しない。** これらはモデルの推奨設定として
`draw-things-cli` の内部で適用され、こちらからは指定も観測もしていない。
値を書けば推測になるため、書かない。`model` が同じなら同じ推奨設定が使われる。

サムネイル生成に失敗しても生成自体は成功扱いになり、その場合 `thumb` は `null`。

---

## 4. `error.json`

失敗は `failed/` に出る。`result.json` とはキーが違う。

```json
{
  "schema_version": 1,
  "job_id": "scene-txt-a1b2c3d4-1788223421-000",
  "status": "failed",
  "error_kind": "invalid_scene",
  "message": "シーン記述として解析できない: `主題` は必須",
  "failed_at": "2026-09-01T09:43:48+09:00"
}
```

`error_kind` は機械判定用の識別子（`invalid_json` `invalid_scene` `out_of_range`
`not_ready` `interrupted` など）。`message` は人間向けで、**文面は予告なく変わる。
分岐に使わないこと。**

入力の検証で落ちた場合は `job_id` が無く、代わりに `<日時>_<元ファイル名>.error.json`
という名前になる。

---

## 5. 下流のツールが踏みやすい前提

**`thumbs/` は30日で自動削除される。`results/` は既定では消さない。**

以前は両方まとめて30日で消していたが、画像が永久に残るのに来歴だけ先に消えるのは
順序が逆だったため分離した。`results/` を消したい場合は
`DTQ_RESULTS_RETENTION_DAYS` に日数を設定する（`0` は無期限）。

→ ただし**消費側で永続化する設計を推奨する。** 保持は設定で変えられるうえ、
`sha256` があればパスに依存せず後から突き合わせ直せる。

**同じ seed で再生成しても、同一の画像にはならない。** GPU の浮動小数点の畳み込み
順序が実行ごとに変わるため、画素の 85% が相違する（平均絶対差 4.85/255、
見た目は区別できない）。

→ **記録された seed から画像を再現できる前提で設計しないこと。** 原本を保持する。

**1つの入力ファイルから複数の `result.json` が出る。** `count` 指定なら seed 違いで
その数だけ、`batch` 指定なら1つの `result.json` の `images` が複数要素になる。
`source` が同じものをまとめれば元の入力単位に戻せる。

**ジョブは直列に1件ずつ処理される。** 同時に複数の `result.json` が現れることはない。

**画像の保存先が dtq 専用である保証はない。** Draw Things アプリが直接書き出した
画像や、CLI を手で叩いて作った画像が同じフォルダに混在しうる。

過去に実際そうなっていた。2253枚のうち dtq 由来は 1995枚で、残り 258枚は来歴を
持たなかった（アプリ由来 224枚、手動生成 33枚、その他1枚）。**この 257枚は
別フォルダへ移したが、混在しない仕組みがあるわけではないので再発しうる。**

アプリ由来の画像は命名規則も違い（プロンプト全体をファイル名にし、`(word:1.6)` の
重み記法を含む）、そこからパラメータを復元することはできない。

→ **フォルダを走査せず、`results/` を起点にすること。** dtq が生成したものだけを
対象にできる。`result.json` の `images[].path` が指すファイルだけが dtq の成果物。

**iCloud 同期の遅延がある。** 別のマシンから読む場合、ファイルが見えていても実体が
無いこと（dataless）がある。同じ Mac 上で読むなら問題ない。

---

## 6. 消費側の実装

```python
import json, pathlib, time

RESULTS = pathlib.Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/DrawThingsQueue/results"
ICLOUD  = RESULTS.parent

seen = set()
while True:
    for f in sorted(RESULTS.glob("*.result.json")):
        if f.name in seen:
            continue
        job = json.loads(f.read_text(encoding="utf-8"))   # 途中書きは無い
        for img in job["images"]:
            original = pathlib.Path(img["path"])          # 絶対パス
            digest = img.get("sha256")                    # パス非依存の同定に使う
            thumb = ICLOUD / img["thumb"] if img.get("thumb") else None
            ...
        seen.add(f.name)
    time.sleep(30)
```

`results/` は既定で消えないが、保持は設定で変えられる。処理済みの記録は
消費側で永続化し、`sha256` を主キーにするとパスの変化にも耐えられる。

**画像フォルダを直接走査してはいけない**（§5）。上の例のように `results/` を
起点にすれば、dtq が生成したものだけを確実に拾える。
