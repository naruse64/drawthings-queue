# dtq — iCloud キュー経由の画像生成ワーカー

外出先の iPhone から iCloud Drive にプロンプトを置くと、Mac が自動で画像を生成する。
接続も認証も不要で、伝送路は iCloud の同期だけ。

移動中に溜めて、帰宅時には全部できている、という使い方を想定している。

---

## 1. 構成

```
iPhone                iCloud Drive              Mac (launchd 常駐)
  .txt / .json  ──▶   queue/          ──▶  ワーカー（直列1本）
                                                    │
                      thumbs/         ◀────────────┤ サムネイル
                      results/        ◀────────────┤ 結果 JSON
                      failed/         ◀────────────┘ 失敗と理由
                                             │
                                     ~/DrawThings/  PNG 原本
```

### iCloud 側（iPhone から見える面）

```
~/Library/Mobile Documents/com~apple~CloudDocs/DrawThingsQueue/
├── queue/      投入口。ここに置く
├── thumbs/     長辺512pxのJPEG。外出先での確認用
├── results/    <job_id>.result.json
├── failed/     失敗したファイルと <job_id>.error.json
└── samples/    見本。コピーして queue に貼るだけで試せる
```

### ローカル側

```
~/Library/Application Support/dtq/
├── app/        launchd が起動する app バンドルとワーカー本体（dtq-setup が配置）
├── models/     生成に使うモデルの複製（APFS クローンで実消費ゼロ）
├── work/       incoming / pending / running
├── ledger/     処理済み job_id の台帳
├── archive/    処理済みジョブ定義の保管
└── tmp/        作業ファイル

~/DrawThings/                            画像原本（PNG、約1MB/枚）
~/Library/Logs/drawthings-queue.log      人間可読ログ
~/Library/Logs/drawthings-queue.jsonl    1ジョブ1行の構造化ログ
```

### リポジトリ

| パス | 役割 |
|---|---|
| `bin/dtq-setup` | モデル取り込み・バンドル構築・launchd 登録。**更新したら再実行する** |
| `bin/dtq-worker` | ワーカー本体 |
| `bin/dtq-status` | 現況表示 |
| `lib/dtq-common.sh` | パスと設定値 |
| `lib/dtq_parse.py` | 入力の検証とジョブ展開 |
| `lib/dtq_emit.py` | JSON の組み立てと読み出し |
| `launchd/agent/` | app バンドルの材料（`launcher.c` / `Info.plist`） |
| `test/dtq-test.sh` | 結合テスト |

---

## 2. 入力

**形式は拡張子ではなく中身で決まる。** 先頭の非空白文字が `{` か `[` なら JSON、
そうでなければ1行1プロンプトのテキストとして扱う。iOS ショートカットが JSON を
`.txt` として保存しても問題ない。

### テキスト形式

1行 = 1プロンプト。空行と `#` で始まる行は無視。

```
a ceramic coffee cup on a wooden desk, morning light through a window
# これはコメント
a black cat sleeping on a stack of old books, warm afternoon light
```

### JSON 形式

単一オブジェクト、または配列で複数ジョブ。

```json
{
  "title": "teapot",
  "prompt": "a cast iron teapot on a slate surface, soft northern light",
  "negative_prompt": "blurry, distorted",
  "seed": 12345,
  "steps": 8,
  "width": 832,
  "height": 1216,
  "count": 3,
  "loras": [{ "file": "realisticsnapshotz_image_turbo_lora_f16.ckpt", "weight": 0.6 }]
}
```

| フィールド | 型 | 既定 | 範囲・制約 |
|---|---|---|---|
| `prompt` | string | **必須** | 1〜2000文字 |
| `title` | string | prompt から自動生成 | 英数と `-` に正規化、40文字まで |
| `negative_prompt` | string | モデル推奨値 | 2000文字まで |
| `seed` | int | ランダム | 0〜2147483647。`-1` もランダム |
| `steps` | int | 8 | 1〜50 |
| `width` / `height` | int | モデル推奨（1024） | 512〜2048 の64の倍数。**両方セットで指定** |
| `batch` | int | 1 | 1〜4。同一 seed のバリエーション |
| `count` | int | 1 | 1〜200。seed を +1 ずつずらして反復 |
| `loras` | array | なし | OKリストのみ。`weight` 0.1〜1.0 |

未知のフィールドはエラーにする。タイプミスを黙って無視しないため。

### シーン記述

`主題: …` のスロット形式でも投入できる。判定は**最初の内容行がスロット名＋
コロン**かどうかだけで、いったんシーンと判定したら以降の行が壊れていても
1行1プロンプトには落とさず `failed/` に送る（JSON と同じ fail-closed）。

```
title:    Beach
主題:     a woman in her twenties
場所:     a seaside promenade
光:       bright sunny weather
negative: blurry, distorted, text
lora:     example_style:0.6
count:    30
```

スロットの一覧と組み立て規則は [dtp.md](dtp.md)。

**使用を許可する LoRA のリスト（OKリスト）**は `config.local.sh` の `DT_LORAS` で決まる。ここに無いものは
ジョブ検証の段階で弾く。別モデル向けの LoRA を誤って指定しても生成前に止められる。

**モデルはジョブから指定できない。** 未取得のモデル名を書かれると必ず失敗し、
外出先からは原因が分からないため。使用するモデルは `config.local.sh` で決める。

---

## 3. 動作

### 検知

定期スイープ（60秒）が本命。`fswatch` があれば待機を早く切り上げる（実測4秒）。
**fswatch が無くても全機能が動く。**

ジョブとジョブの間でもスイープする。長いバッチの処理中に投入されたファイルを
待たせないため。

### 取り込み

次をすべて満たすまで queue から動かさない。

1. iCloud の実体があること（dataless フラグが立っていない）
2. サイズが0でないこと
3. サイズと mtime が5秒間変わらないこと
4. JSON なら `jq empty` を通ること

満たさない場合は queue に残して次のスイープで再試行する。**打ち切りは経過時間で
判断する**（回数ではない）。同期・移動待ちは900秒、JSON の構文エラーは180秒。
超えたら `failed/` へ送る。

条件を満たしたらローカルへ `mv` して抜く。以降そのファイルについて iCloud には触らない。

**job_id** = `<ファイル名>-<内容のSHA256先頭8桁>-<mtime>-<連番>`

mtime を含めることで、「意図的な再投入」（新しい mtime）と「iCloud がファイルを
復活させた」（同一 mtime）を区別する。台帳に載っている job_id は再実行しない。

### 実行

**直列1本のみ。** `gRPCServerCLI` と GPU・メモリを共有しているため。
排他は PID ファイル方式（`set -o noclobber` による O_EXCL + 生存確認）。

```bash
draw-things-cli generate \
  --models-dir ~/Library/Application\ Support/dtq/models \
  --model <config.local.sh で指定したモデル> \
  --prompt-file <一時ファイル> \
  --steps <n> --seed <n> \
  --no-download-missing --disable-preview \
  --config-json <LoRA / batch があれば> \
  -o ~/DrawThings/<title>_<seed>_<YYYYMMDD-HHMMSS>.png
```

- **プロンプトは必ずファイル経由で渡す。** 引用符・改行・シェル特殊文字が壊れず、
  シェル展開もされない
- 引数は配列で組み立て、`eval` は使わない
- `--cfg` `--width` `--height` はジョブで明示されたときだけ付ける
- 子は独立したプロセスグループで動かし、停止時はグループごと落とす

| 項目 | 値 |
|---|---|
| タイムアウト | 900秒。超過でグループへ `SIGTERM` → 10秒後 `SIGKILL` |
| リトライ | 実行エラーは1回だけ（60秒待機後）。検証エラーはリトライしない |
| 遅延警告 | 成功しても300秒を超えたら警告を記録 |

### 出力

- **原本**: `~/DrawThings/` に PNG。iCloud には送らない
- **サムネイル**: `sips -Z 512` で長辺512pxのJPEG（約50KB）を `thumbs/` へ
- **結果**: `results/<job_id>.result.json` に条件・seed・所要時間・保存先
- **失敗**: `failed/` にエラー JSON と**元のファイルを併置**。直して置き直せる

`thumbs/` と `results/` は30日で自動削除。画像原本と `archive/` は削除しない。

### 中断と復帰

- launchd の停止指示による中断は**失敗として数えない**。`running/` に残したまま
  試行回数を戻し、次回起動時のリカバリで再実行する
- クラッシュ後に `running/` に残ったジョブは、試行2回未満なら再投入、
  2回以上なら `failed/` へ

---

## 4. 設定

モデルや LoRA は環境ごとに違うため、外に出してある。

| ファイル | 扱い | 内容 |
|---|---|---|
| `lib/dtq-common.sh` | 追跡 | 既定値。公開モデルを指す |
| `config.example.sh` | 追跡 | 雛形 |
| `config.local.sh` | **git 管理外** | 手元固有の上書き |

```bash
cp config.example.sh config.local.sh
# DT_MODEL と DT_LORAS を書き換える
bin/dtq-setup            # 配置し直す
```

`config.local.sh` が無ければ既定値で動く。`DT_LORAS` は環境変数として検証器にも
渡るので、bash と Python で二重管理にならない。

**モデルを変えたら `DT_MODEL_DEPS` の見直しが要る。** 必要なファイルが足りなければ
`draw-things-cli` がファイル名を挙げて教えてくれるので、それを見て足す。

## 5. 導入

```bash
bin/dtq-setup
```

これだけで、モデルの取り込み・app バンドルの構築・launchd への登録・起動確認まで行う。

初回起動時に **iCloud Drive へのアクセス確認ダイアログ**が一度出るので許可する。
System 設定を手で触る必要はない。許可は
プライバシーとセキュリティ → ファイルとフォルダ に記録される。

**リポジトリを更新したら `dtq-setup` を再実行する。** Draw Things 側でモデルを
更新・追加したときも同じ。

### 前提

| 項目 | 内容 |
|---|---|
| OS | macOS 26 系（Apple Silicon） |
| 電源 | AC 接続かつ `pmset sleep 0`。留守中にスリープしないこと |
| 必須 | `draw-things-cli` / Xcode Command Line Tools / macOS 標準の `jq` `sips` `brctl` `python3` |
| 任意 | `fswatch`（検知が速くなる。無くても動く） |

### 運用コマンド

```bash
bin/dtq-status                                        # 現況
tail -f ~/Library/Logs/drawthings-queue.log           # ログ
launchctl kickstart -k gui/$UID/local.drawthings.queue # 再起動
bin/dtq-setup --uninstall                             # 停止・登録解除
test/dtq-test.sh                                      # 結合テスト
```

---

## 6. 性能

実測値（Mac Studio / 32GB / Z-Image Turbo 系 q8p / steps 8 / 1024×1024 または 832×1216）。

| 項目 | 値 |
|---|---|
| 生成時間 | 1枚あたり 87〜95秒（34枚連続で平均88秒、最長90秒） |
| 検知遅延 | fswatch 経路で約4秒、スイープ経路で最大60秒（+ iCloud 同期時間） |
| モデル複製 | 論理11GB。APFS クローンのため実ディスク消費増は 0MB |
| 画像 | 約1MB/枚（911枚で平均1.06MB）。サムネイルは約40KB |
| `count` 上限 | 200枚。直列処理なので約5時間かかる。ディスクは約210MB |

---

## 7. スコープ外

- img2img / inpaint
- 動画生成
- ジョブのキャンセル・優先度・並び替え
- Mac から iPhone へのプッシュ通知（結果ファイルの出現で代替）
- 複数 Mac での分散実行

---

## 8. 今後の候補

- 完了通知（ntfy / Pushover）
- img2img（入力画像も queue に置く方式）
- モデル切替の解禁（使用を許可するモデルのリストを設ける）
- 夜間限定モード（iPhone アプリとの GPU 競合を避ける）

---

製造・実機導入・実機テストの各工程で判明した知見は [findings.md](findings.md) に分離した。
設計判断の理由を追う場合はそちらを参照。
