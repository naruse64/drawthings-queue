# dtq

外出先の iPhone から iCloud Drive にプロンプトを置くと、Mac が自動で画像を生成する。
接続も認証も不要で、伝送路は iCloud の同期だけ。

```
iPhone ──▶ iCloud Drive/DrawThingsQueue/queue/ ──▶ Mac (launchd 常駐) ──▶ 画像
                              ▲                                         │
                              └──── thumbs / results / failed ──────────┘
```

## 使い方

iCloud Drive の `DrawThingsQueue/queue/` に `.txt` か `.json` を置く。それだけ。

```
a ceramic coffee cup on a wooden desk, morning light through a window
```

```json
{ "prompt": "a cast iron teapot on a slate surface", "seed": 12345, "count": 3 }
```

できあがりは `thumbs/`（サムネイル）と `results/`（詳細）に出る。原本の PNG は
Mac の `~/DrawThings/`。失敗したものは理由とともに `failed/` へ。

`samples/` に見本があるので、iPhone の「ファイル」App でコピーして `queue/` に
貼り付ければすぐ試せる。

## 設定

モデルや LoRA は環境ごとに違うため外に出してある。

```bash
cp config.example.sh config.local.sh
# DT_MODEL と DT_LORAS を書き換える
```

`config.local.sh` は git 管理外。無ければリポジトリの既定値で動く。

## 導入

```bash
bin/dtq-setup
```

モデルの取り込み・app バンドルの構築・launchd への登録・起動確認まで行う。
初回に iCloud へのアクセス確認ダイアログが一度出るので許可する。

**リポジトリや Draw Things 側のモデルを更新したら再実行する。**

## 運用

```bash
bin/dtq-status                                         # 現況
tail -f ~/Library/Logs/drawthings-queue.log            # ログ
launchctl kickstart -k gui/$UID/local.drawthings.queue # 再起動
bin/dtq-setup --uninstall                              # 停止・登録解除
test/dtq-test.sh                                       # 結合テスト
```

### スリープについて

**長時間のバッチを流す前に、Mac がスリープしない設定になっているか確認する。**
`count: 200` は1枚90秒として約5時間かかる。外出時間を超えることもある。

このツールはスリープ設定を変更しない。電源の扱いはシステム全体の設定であり、
常駐エージェントが黙って握ると原因の特定が困難になるため、判断は利用者に委ねる。

```bash
pmset -g | grep -E '^ (sleep|disksleep)'   # どちらも 0 なら寝ない
```

`sleep` が 0 以外なら、システム設定 → エネルギー（ノート型では バッテリー）
から自動スリープを切る。`displaysleep` は画面だけなので生成には影響しない。

スリープしても**ジョブが失敗するわけではない**。生成が中断されて復帰時に再開する
だけで、結果として「帰宅時には終わっているはず」が終わっていないことになる。

生成中だけスリープを抑止したい場合は、バッチを流す間だけ手元で `caffeinate` を
走らせる。エージェント側には組み込んでいない — ワーカーが落ちると解除されるため、
長時間バッチが中断されやすい場面でこそ効かなくなる。

```bash
caffeinate -i -w $(pgrep -f 'bin/dtq-worker' | head -1)
```

## dtp — プロンプト作成の補助

日本語のシーン記述からプロンプトを組み立て、語彙の効果を実測する別の CLI。
ワーカーとは実行時に繋がらない。

```bash
bin/dtp lint    scene.txt      # 書き忘れ・SD1.5 語・重み記法を検査
bin/dtp compose scene.txt      # プロンプトを組み立てる
bin/dtp job     scene.txt      # dtq の job JSON にする
                               # シーン記述はそのまま queue/ に置いてもよい
bin/dtp ab scene.txt --slot 光 --variants "逆光" "順光" "夕方の斜光"
test/dtp-test.sh               # 単体テスト
```

このモデルのテキストエンコーダは Qwen3-VL 4B で、**日本語がそのまま通る**。
翻訳も語彙辞書も持たず、書き忘れを潰すことだけをする。`ab` は1スロットだけ振って
同一シードで生成し、画素差を測る — 同一プロンプトでも画像はビット一致しない
（平均差 4.85/255）ので、その下限に対する倍率で「効いたのか」を判定する。

詳細は [docs/dtp.md](docs/dtp.md)、測定の根拠は [docs/findings.md](docs/findings.md) D 章。

## ドキュメント

| ファイル | 内容 |
|---|---|
| [docs/spec.md](docs/spec.md) | dtq の仕様。入力形式・動作・設定値・性能 |
| [docs/dtp.md](docs/dtp.md) | dtp の仕様。シーン記述・A/B テスト |
| [docs/findings.md](docs/findings.md) | 製造・テスト工程で判明した知見と、設計判断の理由 |

## 必要なもの

| | |
|---|---|
| OS | macOS 26 系（Apple Silicon） |
| アプリ | [Draw Things](https://drawthings.ai/) とそのモデル |
| CLI | `draw-things-cli` |
| ビルド | Xcode Command Line Tools |
| 任意 | `fswatch`（検知が速くなる。無くても動く） |

```bash
brew install drawthingsai/draw-things/draw-things-cli
brew install fswatch          # 任意
xcode-select --install        # 未導入なら
```

Mac が留守中にスリープしないこと（`pmset -g` で `sleep 0` を確認）。

## 構成

| パス | 役割 |
|---|---|
| `bin/dtq-setup` | 導入・更新 |
| `bin/dtq-worker` | ワーカー本体 |
| `bin/dtq-status` | 現況表示 |
| `bin/dtp` | プロンプト作成の補助（ワーカーとは独立） |
| `lib/` | 設定・入力検証・JSON 組み立て |
| `launchd/` | plist テンプレートと app バンドルの材料 |
| `samples/` | 入力例 |
| `test/` | テスト（dtq 179件 / dtp 71件） |
| `config.example.sh` | 手元設定の雛形 |

## ライセンス

MIT
