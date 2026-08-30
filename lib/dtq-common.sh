#!/bin/bash
# dtq 共通定義。bash 3.2 互換（連想配列・mapfile を使わない）。

# このファイルの位置からリポジトリルートを決める。config.local.sh の解決に使う。
DTQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- iCloud 側（iPhone から見える面） ----
ICLOUD_ROOT="${DTQ_ICLOUD_ROOT:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/DrawThingsQueue}"
Q_DIR="$ICLOUD_ROOT/queue"
THUMBS_DIR="$ICLOUD_ROOT/thumbs"
RESULTS_DIR="$ICLOUD_ROOT/results"
FAILED_DIR="$ICLOUD_ROOT/failed"

# ---- ローカル側 ----
STATE_ROOT="${DTQ_STATE_ROOT:-$HOME/Library/Application Support/dtq}"
INCOMING_DIR="$STATE_ROOT/work/incoming"
PENDING_DIR="$STATE_ROOT/work/pending"
RUNNING_DIR="$STATE_ROOT/work/running"
LEDGER_DIR="$STATE_ROOT/ledger"
ARCHIVE_DIR="$STATE_ROOT/archive"
TRIES_DIR="$STATE_ROOT/tries"
TMP_DIR="$STATE_ROOT/tmp"
LOCK_FILE="$STATE_ROOT/worker.lock"

# 画像原本の保存先。/Applications 配下に置くと macOS が「アプリ管理」の
# 管轄とみなし、インストール済みアプリを改変できる強い権限を要求してくる。
# PNG を書くだけのエージェントには過剰なので、ホーム直下に置く。
# ここは追加の TCC 許可なしで書けることを実機で確認済み。
IMAGES_DIR="${DTQ_IMAGES_DIR:-$HOME/DrawThings}"
LOG_FILE="${DTQ_LOG_FILE:-$HOME/Library/Logs/drawthings-queue.log}"
JSONL_FILE="${DTQ_JSONL_FILE:-$HOME/Library/Logs/drawthings-queue.jsonl}"

# ---- 生成設定（モデルはジョブから指定させない） ----
#
# ここに書くのは公開モデルの既定値。実際にどのモデルを使うかは環境ごとに
# 違うので、手元固有の指定は config.local.sh に書く（git 管理外）。
# 雛形は config.example.sh。
DT_MODEL="z_image_turbo_1.0_q8p.ckpt"

# 使用を許可する LoRA。ここに無いものはジョブ検証の段階で弾く。
# 別モデル向けの LoRA を誤って指定しても、生成前に止められる。
DT_LORAS=(
  "realisticsnapshotz_image_turbo_lora_f16.ckpt"
)

# モデル本体以外に generate が要求するファイル。
# 不足があると CLI が名前を挙げて教えてくれるので、それを見て足す。
DT_MODEL_DEPS=(
  "qwen_3_vl_4b_instruct_q8p.ckpt"                # テキストエンコーダ
  "qwen_3_vl_4b_instruct_q8p.ckpt-tensordata"     # 同上の重み
  "flux_1_vae_f16.ckpt"                           # VAE
  "custom.json"
  "custom_lora.json"
  "custom_prompt_style.json"
)

DT_CLI="${DTQ_CLI:-/opt/homebrew/bin/draw-things-cli}"

# モデルはローカルへ複製したものを使い、Draw Things のコンテナには触れない。
#
# コンテナ（~/Library/Containers/com.liuliu.draw-things/...）を launchd 配下から
# 読むと TCC が「ほかのアプリからのデータ」の許可を求める。しかもこの許可は
# エージェントを再起動するたびに失効し、そのつどダイアログが出る。承認されるまで
# draw-things-cli は死なずに待ち続けるため、無人運用が成立しない。
#
# 複製は dtq-setup（＝ターミナル実行で権限を持つ）でのみ行う。
DT_SOURCE_MODELS="$HOME/Library/Containers/com.liuliu.draw-things/Data/Documents/Models"
MODELS_DIR="${DTQ_MODELS_DIR:-$STATE_ROOT/models}"

# 手元固有の上書き。モデル名や LoRA など、環境ごとに違うものはここで差し替える。
# git 管理外なので、公開リポジトリに個人の設定が乗らない。
DTQ_CONFIG_LOCAL="${DTQ_CONFIG_LOCAL:-$DTQ_ROOT/config.local.sh}"
if [ -f "$DTQ_CONFIG_LOCAL" ]; then
  . "$DTQ_CONFIG_LOCAL"
fi

# 複製対象は上書きを反映してから組み立てる。
DT_REQUIRED_MODELS=( "$DT_MODEL" "${DT_MODEL_DEPS[@]}" "${DT_LORAS[@]}" )

# 検証器（python）にホワイトリストを渡す。bash 側と二重管理しないため。
export DTQ_LORA_WHITELIST="$(printf '%s\n' "${DT_LORAS[@]}")"

# ---- チューニング定数（§05〜§07） ----
SWEEP_INTERVAL="${DTQ_SWEEP_INTERVAL:-60}"   # 定期スイープ間隔（本命の検知手段）
STABLE_WAIT="${DTQ_STABLE_WAIT:-5}"          # 安定判定の再測定までの待ち
GEN_TIMEOUT="${DTQ_GEN_TIMEOUT:-900}"        # generate 1回のタイムアウト
KILL_GRACE=10                                # SIGTERM から SIGKILL までの猶予
RETRY_WAIT="${DTQ_RETRY_WAIT:-60}"           # 実行エラー後の再試行待ち
# 生成が異常に長引いたときの警告しきい値。実測は 88〜104秒。
# TCC のダイアログ待ちでブロックされると数百秒に伸びるが、成功はするので
# ログ上は正常に見えてしまう。無人運用では誰も気づけないため明示的に記録する。
SLOW_GEN_WARN="${DTQ_SLOW_GEN_WARN:-300}"
MAX_ATTEMPTS=2                               # 実行は最大2回（初回+リトライ1）
# 取り込みを諦めるまでの「経過時間」。回数ではないことが重要。
# fswatch は iCloud のダウンロード進行中に何度も発火するため、回数で数えると
# スイープが 9〜11秒間隔で回って 40秒で上限に達してしまう（実測）。
INTAKE_DEADLINE="${DTQ_INTAKE_DEADLINE:-900}"   # 同期・移動待ちの上限（15分）
PARSE_DEADLINE="${DTQ_PARSE_DEADLINE:-180}"     # JSON が壊れたままの上限（3分）
RETENTION_DAYS=30                            # thumbs/ results/ の保持日数
LOG_MAX_BYTES=$((10 * 1024 * 1024))          # 10MB でローテート
CLEANUP_INTERVAL=21600                       # 保持期間スイープは6時間ごと

# ---- インタプリタ解決 ----
# brew の python が更新されてもデーモンが壊れないよう、システム python を優先する。
if [ -x /usr/bin/python3 ]; then
  DTQ_PY=/usr/bin/python3
else
  DTQ_PY="$(command -v python3 2>/dev/null)"
fi

DTQ_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DTQ_PARSE="$DTQ_LIB/dtq_parse.py"
DTQ_EMIT="$DTQ_LIB/dtq_emit.py"

# ---- ログ ----
log() {
  printf '%s [dtq] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# 構造化ログ。値のエスケープは python に任せる（プロンプトに引用符・改行が入るため）。
log_event() {
  "$DTQ_PY" "$DTQ_EMIT" event "$@" >> "$JSONL_FILE" 2>/dev/null || true
}

rotate_one() {
  local f="$1" sz
  [ -f "$f" ] || return 0
  sz=$(stat -f '%z' "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$LOG_MAX_BYTES" ]; then
    rm -f "$f.2" 2>/dev/null
    [ -f "$f.1" ] && mv "$f.1" "$f.2"
    mv "$f" "$f.1"
    : > "$f"
  fi
}

rotate_logs() {
  rotate_one "$LOG_FILE"
  rotate_one "$JSONL_FILE"
}

ensure_dirs() {
  local d
  for d in "$Q_DIR" "$THUMBS_DIR" "$RESULTS_DIR" "$FAILED_DIR" "$MODELS_DIR" \
           "$INCOMING_DIR" "$PENDING_DIR" "$RUNNING_DIR" \
           "$LEDGER_DIR" "$ARCHIVE_DIR" "$TRIES_DIR" "$TMP_DIR" \
           "$IMAGES_DIR" "$(dirname "$LOG_FILE")"; do
    mkdir -p "$d" 2>/dev/null || { log "FATAL: ディレクトリを作れない: $d"; return 1; }
  done
  return 0
}

# プロセスグループごと落とす。ラッパースクリプト経由のコマンドは、親だけ殺しても
# 実際の作業をしている孫が孤児として残るため、グループに送る。
terminate_group() {
  local pid="$1" sig="$2"
  kill "-$sig" "-$pid" 2>/dev/null || kill "-$sig" "$pid" 2>/dev/null
  return 0
}

# コマンドをタイムアウト付きで実行する。macOS に timeout(1) が無いための自前実装。
# 使い方: run_with_timeout <秒> <コマンド...>
# 戻り値: コマンドの終了コード。タイムアウト時は 124。
run_with_timeout() {
  local secs="$1"; shift
  : "${CURRENT_CHILD:=}"
  local pid wd rc timedout_flag owner
  timedout_flag="$TMP_DIR/timeout.$$.$RANDOM"
  owner=$$   # ワーカー本体。見張り役はこれの生死も見る

  # set -m で子を独立したプロセスグループにし、まとめて落とせるようにする。
  set -m
  "$@" &
  pid=$!
  set +m
  CURRENT_CHILD="$pid"

  (
    local i=0
    while [ "$i" -lt "$secs" ]; do
      kill -0 "$pid" 2>/dev/null || exit 0
      # ワーカーが SIGKILL などで消えたら、子を道連れにして終わる。
      # 放置すると draw-things-cli が GPU を掴んだまま最大 GEN_TIMEOUT 秒残り、
      # launchd が起動し直した次のワーカーと競合する。
      if ! kill -0 "$owner" 2>/dev/null; then
        terminate_group "$pid" TERM
        exit 0
      fi
      sleep 1
      i=$((i + 1))
    done
    kill -0 "$pid" 2>/dev/null || exit 0
    : > "$timedout_flag"
    terminate_group "$pid" TERM
    local j=0
    while [ "$j" -lt "$KILL_GRACE" ]; do
      kill -0 "$pid" 2>/dev/null || exit 0
      sleep 1
      j=$((j + 1))
    done
    terminate_group "$pid" KILL
  ) &
  wd=$!

  wait "$pid"
  rc=$?
  CURRENT_CHILD=""

  kill -TERM "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null

  if [ -f "$timedout_flag" ]; then
    rm -f "$timedout_flag"
    return 124
  fi
  return "$rc"
}

# 単一インスタンスの保証。
#
# ファイルディスクリプタでロックを持つ方式（lockf に fd 番号を渡す）は使えない。
# bash は exec で開いた fd を内部で別番号に複製することがあり、`9>&-` では
# 閉じきれず、sleep などの子プロセスがロックを継承したまま孤児化して
# ロックを握り続けるため。実際 lsof で fd 12 として観測した。
#
# 代わりに PID ファイルを使う。noclobber による O_EXCL で作成を原子化し、
# 残っていた場合は「そのPIDが生きていて、かつ本当に dtq-worker か」を確かめる。
# プロセスが死んでいれば stale とみなして奪う。PID 再利用にも耐える。
acquire_lock() {
  local existing
  if [ -f "$LOCK_FILE" ]; then
    existing="$(cat "$LOCK_FILE" 2>/dev/null)"
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null &&
       ps -o command= -p "$existing" 2>/dev/null | grep -q 'dtq-worker'; then
      return 1
    fi
    rm -f "$LOCK_FILE" 2>/dev/null
  fi
  ( set -o noclobber; printf '%s' "$$" > "$LOCK_FILE" ) 2>/dev/null || return 1
  return 0
}

release_lock() {
  # 自分が持っているときだけ消す。奪われたあとに消してしまわないように。
  [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ] && rm -f "$LOCK_FILE" 2>/dev/null
  return 0
}
