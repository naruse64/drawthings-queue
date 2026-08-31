#!/bin/bash
# dtq の結合テスト。docs/queue-requirements.md §13 の受け入れ基準に対応する。
# draw-things-cli はスタブに差し替え、iCloud/状態/画像の各ディレクトリも
# サンドボックスに向けるので、実環境には一切触れない。
set -uo pipefail

DTQ_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="${DTQ_TEST_SANDBOX:-/tmp/dtq-test-$$}"
STUB="$(dirname "${BASH_SOURCE[0]}")/fake-dt-cli"

PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期待=[$3] 実際=[$2]"; fi; }

nfiles() { find "$1" -maxdepth 1 -type f ${2:+-name "$2"} 2>/dev/null | wc -l | tr -d ' '; }

# 起動中のスタブ CLI とその子。コマンド全体を前方一致で見る。
stub_procs()  { ps -axo command= | grep -c "^/bin/bash $STUB "; }
stub_sleeps() { ps -axo command= | grep -c '^sleep 120$'; }

# 非同期に消える／現れるものは、一定時間ポーリングしてから判定する。
# kill 直後は終了処理中で数が合わないことがある。
poll_until() {
  local want="$1" fn="$2" limit="${3:-10}" i=0
  while [ "$i" -lt "$limit" ]; do
    [ "$($fn)" = "$want" ] && break
    sleep 1
    i=$((i + 1))
  done
  $fn
}

reset_sandbox() {
  pkill -f "$STUB" >/dev/null 2>&1
  pkill -f 'fswatch -1' >/dev/null 2>&1
  rm -rf "$SB"
  mkdir -p "$SB/icloud" "$SB/state" "$SB/images" "$SB/logs"
  export DTQ_ICLOUD_ROOT="$SB/icloud"
  export DTQ_STATE_ROOT="$SB/state"
  export DTQ_IMAGES_DIR="$SB/images"
  # ワーカーは実行前にモデルの実在を確かめる。スタブ CLI は中身を見ないので
  # 空ファイルで足りる。
  # 手元の config.local.sh に影響されず、リポジトリの既定値でテストする
  export DTQ_CONFIG_LOCAL="$SB/no-such-config.sh"
  export DTQ_MODELS_DIR="$SB/models"
  mkdir -p "$SB/models"
  : > "$SB/models/z_image_turbo_1.0_q8p.ckpt"
  export DTQ_LOG_FILE="$SB/logs/worker.log"
  export DTQ_JSONL_FILE="$SB/logs/worker.jsonl"
  export DTQ_CLI="$STUB"
  export DTQ_STABLE_WAIT=1
  export DTQ_RETRY_WAIT=1
  export DTQ_GEN_TIMEOUT=900
  export DTQ_SLOW_GEN_WARN=300
  export DTQ_INTAKE_DEADLINE=900
  export DTQ_PARSE_DEADLINE=180
  export DTQ_FAKE_LOG="$SB/logs/cli-calls.log"
  export DTQ_FAKE_MODE=ok
  rm -f "$DTQ_FAKE_LOG" "$DTQ_FAKE_LOG.count"
  unset DTQ_FAKE_DROP
  : > "$DTQ_FAKE_LOG"
  Q="$SB/icloud/queue"; TH="$SB/icloud/thumbs"; RS="$SB/icloud/results"; FL="$SB/icloud/failed"
  PEND="$SB/state/work/pending"; RUN="$SB/state/work/running"; LED="$SB/state/ledger"
  mkdir -p "$Q" "$TH" "$RS" "$FL"
}

# 本番では launchd が stdout/stderr を LOG_FILE へ流す（worker 自身は書かない）。
# テストでも同じ形にしないと、ログに関する検証ができない。
sweep() { "$DTQ_HOME/bin/dtq-worker" --once >> "$DTQ_LOG_FILE" 2>&1; }

banner() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 1
banner "1. .txt を1行置く → 生成され、サムネイルと結果が出る"
reset_sandbox
echo 'a ceramic coffee cup on a wooden desk, morning light' > "$Q/one.txt"
sweep
check "画像が1枚できた"       "$(nfiles "$SB/images")" 1
check "サムネイルが1枚できた" "$(nfiles "$TH")"        1
check "結果JSONが1件出た"     "$(nfiles "$RS")"        1
check "queue が空になった"    "$(nfiles "$Q")"         0
check "failed は空"           "$(nfiles "$FL")"        0
res="$(find "$RS" -name '*.result.json' | head -1)"
check "status=success"        "$(jq -r .status "$res")" "success"
check "画像1件が記録された"   "$(jq -r '.images|length' "$res")" 1
check "サムネイルパスが入った" "$(jq -r '.images[0].thumb' "$res" | cut -c1-7)" "thumbs/"
check "duration が入った"     "$(jq -r 'has("duration_sec")' "$res")" "true"
png="$(find "$SB/images" -name '*.png' | head -1)"
check "命名が <title>_<seed>_<ts>.png" \
  "$(basename "$png" | grep -cE '^[a-z0-9-]+_[0-9]+_[0-9]{8}-[0-9]{6}\.png$')" 1

# ---------------------------------------------------------------- 2
banner "2. .txt 3行 → 3枚。コメントと空行は無視される"
reset_sandbox
printf 'first prompt here\n\n# comment line\nsecond prompt here\nthird prompt here\n' > "$Q/three.txt"
sweep
check "3枚生成された"     "$(nfiles "$SB/images")" 3
check "結果が3件"         "$(nfiles "$RS")"        3
check "seed が3つとも別"  "$(jq -rs '[.[].seed]|unique|length' $(find "$RS" -name '*.json'))" 3

# ---------------------------------------------------------------- 3
banner "3. 壊れた JSON は期限まで持ち越し、超えたら failed。ワーカーは生き残る"
reset_sandbox
export DTQ_PARSE_DEADLINE=3600      # 十分長い期限
printf '{"prompt": "broken' > "$Q/bad.json"
sweep; check "1回目は持ち越し"                 "$(nfiles "$Q" '*.json')" 1
sweep; check "2回目も持ち越し"                 "$(nfiles "$Q" '*.json')" 1
sweep; check "3回目も持ち越し（回数では切らない）" "$(nfiles "$Q" '*.json')" 1
check "  failed には落ちていない"              "$(nfiles "$FL")" 0
check "  待機がログに残る"                     "$(grep -c '取り込み待ち' "$DTQ_LOG_FILE")" 1

export DTQ_PARSE_DEADLINE=0          # 期限切れとして扱わせる
sweep
check "期限を過ぎたら queue から消える" "$(nfiles "$Q" '*.json')" 0
check "元ファイルとエラーが併置される"  "$(nfiles "$FL")" 2
err="$(find "$FL" -name '*.error.json' | head -1)"
check "  error_kind=not_ready"          "$(jq -r .error_kind "$err")" "not_ready"
check "  理由が分かる"                  "$(jq -r .message "$err" | grep -c 'JSON')" 1

export DTQ_PARSE_DEADLINE=180
echo 'still alive after failure' > "$Q/after.txt"
sweep
check "後続ジョブは通常どおり処理される" "$(nfiles "$SB/images")" 1

# ---------------------------------------------------------------- 4
banner "4. 中断ジョブのリカバリ（§08）"
reset_sandbox
mkdir -p "$RUN"
cat > "$RUN/x-aaaa1111-100-000.job.json" <<'J'
{"job_id":"x-aaaa1111-100-000","source":"x.txt","title":"resumable","prompt":"resume me",
 "negative_prompt":null,"seed":11,"steps":8,"width":null,"height":null,"batch":1,
 "loras":[],"attempts":0,"created_at":"2026-08-29T00:00:00+09:00"}
J
cat > "$RUN/x-aaaa1111-100-001.job.json" <<'J'
{"job_id":"x-aaaa1111-100-001","source":"x.txt","title":"exhausted","prompt":"give up on me",
 "negative_prompt":null,"seed":12,"steps":8,"width":null,"height":null,"batch":1,
 "loras":[],"attempts":2,"created_at":"2026-08-29T00:00:00+09:00"}
J
sweep
check "attempts<2 は再実行された"      "$(nfiles "$SB/images")" 1
check "attempts>=2 は failed に落ちた" "$(nfiles "$FL" 'x-aaaa1111-100-001.*')" 2
check "  error_kind=interrupted"      "$(jq -r .error_kind "$FL/x-aaaa1111-100-001.error.json")" "interrupted"
check "  打ち切った方は再実行されない" "$(grep -c 'give up on me' "$DTQ_FAKE_LOG")" 0
check "running が空になった"           "$(nfiles "$RUN")" 0
check "再実行された方は成功" "$(jq -r .status "$(find "$RS" -name '*-000.result.json')")" "success"

# ---------------------------------------------------------------- 5
banner "5. 冪等性 — iCloud の復活は弾き、保存し直しは通す（§05）"
reset_sandbox
echo 'idempotency probe' > "$Q/dup.txt"
touch -t 202608290900 "$Q/dup.txt"
sweep
check "初回は生成される" "$(nfiles "$SB/images")" 1
# 同一内容・同一 mtime のファイルが iCloud で復活した状況
echo 'idempotency probe' > "$Q/dup.txt"
touch -t 202608290900 "$Q/dup.txt"
sweep
check "復活ファイルは再実行されない" "$(nfiles "$SB/images")" 1
check "queue からは消えている"       "$(nfiles "$Q")" 0
# 同じ内容でも保存し直した（mtime が新しい）ものは新規ジョブ
echo 'idempotency probe' > "$Q/dup.txt"
touch -t 202608291000 "$Q/dup.txt"
sweep
check "保存し直しは新規ジョブとして通る" "$(nfiles "$SB/images")" 2

# ---------------------------------------------------------------- 6
banner "6. 検証エラーはリトライせず failed（§04）"
for probe in \
  '{"prompt":"x","loras":[{"file":"tareme_lora.ckpt","weight":0.6}]}|lora_not_allowed' \
  '{"seed":1}|missing_prompt' \
  '{"prompt":"x","width":1024}|incomplete_size' \
  '{"prompt":"x","width":1000,"height":1000}|not_multiple_of_64' \
  '{"prompt":"x","steps":99}|out_of_range' \
  '{"prompt":"x","seed":-2}|out_of_range' \
  '{"prompt":"x","batch":9}|out_of_range' \
  '{"prompt":"x","promt":"typo"}|unknown_field' \
  '{"prompt":"x","loras":[{"file":"realisticsnapshotz_image_turbo_lora_f16.ckpt","weight":3}]}|out_of_range'
do
  body="${probe%|*}"; want="${probe##*|}"
  reset_sandbox
  printf '%s' "$body" > "$Q/v.json"
  sweep
  got="$(jq -r .error_kind "$(find "$FL" -name '*.error.json' | head -1)" 2>/dev/null)"
  check "$want を検出" "$got" "$want"
  check "  リトライせず画像は作られない" "$(nfiles "$SB/images")" 0
done

# ---------------------------------------------------------------- 7
banner "7. プロンプトがシェルに壊されない・展開されない（§06）"
reset_sandbox
cat > "$Q/tricky.json" <<'J'
{"title":"tricky","prompt":"a cup $(touch /tmp/dtq-pwned) with \"quotes\" and 'single' & | ; 日本語 backtick `x`",
 "negative_prompt":"blurry, $HOME","seed":777}
J
rm -f /tmp/dtq-pwned
sweep
check "コマンド置換が実行されていない" "$([ -e /tmp/dtq-pwned ] && echo yes || echo no)" "no"
sent="$(grep -A0 '^prompt=' "$DTQ_FAKE_LOG" | head -1)"
check "プロンプトが原文のまま CLI に届く" \
  "$sent" 'prompt=[a cup $(touch /tmp/dtq-pwned) with "quotes" and '"'"'single'"'"' & | ; 日本語 backtick `x`]'
check "negative も原文のまま" "$(grep '^negative=' "$DTQ_FAKE_LOG" | head -1)" 'negative=[blurry, $HOME]'
check "生成は成功する" "$(nfiles "$SB/images")" 1

# ---------------------------------------------------------------- 8
banner "8. count / batch / LoRA / サイズ の受け渡し（§04・§06）"
reset_sandbox
printf '{"prompt":"counted","seed":100,"count":3}' > "$Q/c.json"
sweep
check "count=3 で3枚"           "$(nfiles "$SB/images")" 3
check "seed が 100,101,102"     "$(jq -rs '[.[].seed]|sort|join(",")' $(find "$RS" -name '*.json'))" "100,101,102"

reset_sandbox
printf '{"prompt":"batched","seed":5,"batch":2}' > "$Q/b.json"
sweep
check "batch=2 で1ジョブ2枚"    "$(nfiles "$SB/images")" 2
check "結果JSONは1件で2枚記録"  "$(jq -r '.images|length' "$(find "$RS" -name '*.json'|head -1)")" 2
check "batchSize が CLI に渡る" "$(grep -c '"batchSize": *2' "$DTQ_FAKE_LOG")" 1

reset_sandbox
printf '{"prompt":"lora","seed":5,"loras":[{"file":"realisticsnapshotz_image_turbo_lora_f16.ckpt","weight":0.55}],"width":832,"height":1216}' > "$Q/l.json"
sweep
check "LoRA が config-json に載る" "$(grep -c 'realisticsnapshotz_image_turbo_lora_f16.ckpt' "$DTQ_FAKE_LOG")" 1
check "width が渡る"               "$(grep -c '^w=832$' "$DTQ_FAKE_LOG")" 1
check "height が渡る"              "$(grep -c '^h=1216$' "$DTQ_FAKE_LOG")" 1

reset_sandbox
printf '{"prompt":"plain","seed":5}' > "$Q/p.json"
sweep
check "上書きが無ければ config-json を付けない" "$(grep -c '^cfg=$' "$DTQ_FAKE_LOG")" 1
check "サイズ未指定なら --width を付けない"     "$(grep -c '^w=$' "$DTQ_FAKE_LOG")" 1

# ---------------------------------------------------------------- 9
banner "9. 実行エラーのリトライは1回だけ（§07）"
reset_sandbox
export DTQ_FAKE_MODE=fail
echo 'this will always fail' > "$Q/f.txt"
sweep
check "CLI は2回呼ばれた（初回+リトライ1）" "$(grep -c '^--- invocation ---$' "$DTQ_FAKE_LOG")" 2
err="$(find "$FL" -name '*.error.json' | head -1)"
check "error_kind=generate_failed" "$(jq -r .error_kind "$err")" "generate_failed"
check "exit_code が記録される"     "$(jq -r .exit_code "$err")" "3"
check "stderr が残る"              "$(jq -r .stderr_tail "$err" | grep -c boom)" 1
check "ジョブ定義も併置される"     "$(nfiles "$FL" '*.job.json')" 1
check "attempts=2"                 "$(jq -r .attempts "$err")" "2"

banner "9b. 一時的な失敗はリトライで回復する"
reset_sandbox
export DTQ_FAKE_MODE=flaky
echo 'transient failure then success' > "$Q/t.txt"
sweep
check "2回目で成功した"   "$(nfiles "$SB/images")" 1
check "failed は空"       "$(nfiles "$FL")" 0
check "結果に attempts=2" "$(jq -r .attempts "$(find "$RS" -name '*.json'|head -1)")" "2"

# ---------------------------------------------------------------- 10
banner "10. タイムアウトで打ち切られる（§07）"
reset_sandbox
export DTQ_FAKE_MODE=hang
export DTQ_GEN_TIMEOUT=2
export DTQ_RETRY_WAIT=1
echo 'this will hang' > "$Q/h.txt"
t0=$(date +%s)
sweep
t1=$(date +%s)
err="$(find "$FL" -name '*.error.json' | head -1)"
check "error_kind=timeout" "$(jq -r .error_kind "$err")" "timeout"
check "exit_code=124"      "$(jq -r .exit_code "$err")" "124"
if [ $((t1-t0)) -lt 40 ]; then ok "2秒×2回+待機で打ち切られた（実測 $((t1-t0))秒）"
else bad "打ち切りが効いていない" "$((t1-t0))秒かかった"; fi
check "ハングした CLI が残っていない"   "$(poll_until 0 stub_procs)" 0
check "その子の sleep も残っていない" "$(poll_until 0 stub_sleeps)" 0

# ---------------------------------------------------------------- 11
banner "11. 雑多な入力を無視する"
reset_sandbox
echo x > "$Q/.DS_Store"; echo x > "$Q/notes.md"; mkdir -p "$Q/subdir"
echo 'real prompt' > "$Q/real.txt"
sweep
check ".DS_Store と .md は無視"   "$(nfiles "$SB/images")" 1
check "無関係なファイルは残る"   "$(nfiles "$Q")" 2
reset_sandbox
printf '\n\n#only comments\n' > "$Q/empty.txt"
sweep
check "実行対象ゼロは failed 扱い" "$(jq -r .error_kind "$(find "$FL" -name '*.error.json'|head -1)")" "empty"

# ---------------------------------------------------------------- 12
banner "12. 保持期間の掃除は thumbs/results だけ（§07）"
reset_sandbox
echo 'retention probe' > "$Q/r.txt"
sweep
touch -t 202501010000 "$TH"/*.jpg "$RS"/*.json
old_png="$(find "$SB/images" -name '*.png' | head -1)"
touch -t 202501010000 "$old_png"
rm -f "$SB/state/.cleanup-marker"
( export DTQ_SWEEP_INTERVAL=1
  "$DTQ_HOME/bin/dtq-worker" --once >/dev/null 2>&1 )
check "古いサムネイルは消える" "$(nfiles "$TH")" 0
check "古い結果JSONも消える"   "$(nfiles "$RS")" 0
check "画像原本は消さない"     "$(nfiles "$SB/images")" 1
check "archive も残る"         "$(nfiles "$SB/state/archive")" 2

# ---------------------------------------------------------------- 13
banner "13. ロックとプロセスの後始末（§06 直列1本の保証）"
reset_sandbox
export DTQ_SWEEP_INTERVAL=30

# ワーカー本体だけを数える。run_with_timeout が作る watchdog サブシェルは
# ps 上のコマンドラインが親と同一なので、単純な grep -c だと二重計上になる。
# 親も一致リストに居るプロセス（＝サブシェル）を除外する。
live() {
  /usr/bin/python3 - "$DTQ_HOME/bin/dtq-worker" <<'PYL'
import subprocess, sys
target = "/bin/bash " + sys.argv[1]
out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="],
                     capture_output=True, text=True).stdout
rows = []
for line in out.splitlines():
    parts = line.strip().split(None, 2)
    if len(parts) == 3 and parts[2] == target:
        rows.append((parts[0], parts[1]))
pids = {pid for pid, _ in rows}
print(sum(1 for pid, ppid in rows if ppid not in pids))
PYL
}
locked() {
  local p; p="$(cat "$SB/state/worker.lock" 2>/dev/null)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo yes; else echo no; fi
}

"$DTQ_HOME/bin/dtq-worker" > "$SB/logs/a.out" 2>&1 &
W=$!
sleep 3
check "ワーカーは1本だけ"        "$(live)" 1
check "ロックを保持している"      "$(locked)" "yes"
check "launchd が見る PID は worker 自身" "$(cat "$SB/state/worker.lock")" "$W"

"$DTQ_HOME/bin/dtq-worker" --once > "$SB/logs/b.out" 2>&1
check "2本目は起動を諦める" "$(grep -c '他のワーカーが動作中' "$SB/logs/b.out")" 1
check "  2本目を弾いても1本のまま" "$(live)" 1

kill -TERM $W; wait $W 2>/dev/null
sleep 2
check "SIGTERM で完全に停止した"   "$(live)" 0
check "停止ログが出ている"         "$(grep -c 'worker 停止' "$SB/logs/a.out")" 1
check "ロックが解放された"         "$(locked)" "no"

banner "13b-1. 生成中に SIGKILL されても CLI を GPU に残さない"
reset_sandbox
export DTQ_SWEEP_INTERVAL=30
export DTQ_FAKE_MODE=hang
export DTQ_GEN_TIMEOUT=600
echo 'kill me mid-generation' > "$Q/k.txt"
"$DTQ_HOME/bin/dtq-worker" > "$SB/logs/a.out" 2>&1 &
W=$!
sleep 8
check "生成が始まっている" "$(poll_until 1 stub_procs)" 1
kill -KILL $W 2>/dev/null; wait $W 2>/dev/null
check "見張り役が CLI を道連れにする" "$(poll_until 0 stub_procs 15)" 0
check "その子の sleep も残らない"     "$(poll_until 0 stub_sleeps 15)" 0
check "ワーカーも残らない"            "$(poll_until 0 live 15)" 0

banner "13b. SIGKILL されてもロックは残らない"
reset_sandbox
export DTQ_SWEEP_INTERVAL=30
"$DTQ_HOME/bin/dtq-worker" > "$SB/logs/a.out" 2>&1 &
W=$!
sleep 3
kill -KILL $W 2>/dev/null; wait $W 2>/dev/null; sleep 2
check "プロセスは残らない"       "$(poll_until 0 live 40)" 0
check "ロックは残らない"         "$(locked)" "no"
"$DTQ_HOME/bin/dtq-worker" --once > "$SB/logs/c.out" 2>&1
check "次のワーカーが起動できる" "$(grep -c '他のワーカーが動作中' "$SB/logs/c.out")" 0

banner "13c. 生成中に停止しても CLI を孤児にせず、ジョブは失われない"
reset_sandbox
export DTQ_SWEEP_INTERVAL=30
export DTQ_FAKE_MODE=hang
export DTQ_GEN_TIMEOUT=600
echo 'interrupt me mid-generation' > "$Q/i.txt"
"$DTQ_HOME/bin/dtq-worker" > "$SB/logs/a.out" 2>&1 &
W=$!
sleep 8
check "生成が始まっている" "$(grep -c 'generate 開始' "$SB/logs/a.out")" 1
check "CLI が動いている"   "$(poll_until 1 stub_procs)" 1
kill -TERM $W; wait $W 2>/dev/null; sleep 3
check "CLI が孤児として残らない"   "$(poll_until 0 stub_procs)" 0
check "その子の sleep も残らない" "$(poll_until 0 stub_sleeps)" 0
check "中断と記録された"         "$(grep -c '停止指示により中断' "$SB/logs/a.out")" 1
check "ジョブは running/ に残る" "$(nfiles "$RUN" '*.job.json')" 1
check "failed には落ちない"      "$(nfiles "$FL")" 0
check "試行回数は戻されている"   "$(jq -r .attempts "$(find "$RUN" -name '*.job.json'|head -1)")" "0"

export DTQ_FAKE_MODE=ok
"$DTQ_HOME/bin/dtq-worker" --once >/dev/null 2>&1
check "再起動で中断ジョブが完走する" "$(nfiles "$SB/images")" 1
check "running が空になった"         "$(nfiles "$RUN")" 0

# ---------------------------------------------------------------- 14
banner "14. 検知経路（§05）"
reset_sandbox
export DTQ_SWEEP_INTERVAL=60

"$DTQ_HOME/bin/dtq-worker" > "$SB/logs/a.out" 2>&1 &
W=$!
sleep 4   # 初回スイープを終えて待機に入るまで待つ
T0=$(date +%s)
echo 'latency probe' > "$Q/late.txt"
i=0
while [ "$i" -lt 70 ]; do
  [ "$(nfiles "$SB/images")" = "1" ] && break
  sleep 1; i=$((i + 1))
done
T1=$(date +%s)
kill -TERM $W; wait $W 2>/dev/null; sleep 1

check "投入したジョブは生成された" "$(nfiles "$SB/images")" 1
if command -v fswatch >/dev/null 2>&1; then
  if [ $((T1 - T0)) -lt 30 ]; then
    ok "fswatch 経路で待機を切り上げた（スイープ60s に対し実測 $((T1-T0))秒）"
  else
    bad "fswatch が効いていない" "$((T1-T0))秒かかった（スイープ間隔60秒を待っている）"
  fi
else
  ok "fswatch 未導入のためスイープ経路のみ（実測 $((T1-T0))秒）"
fi
check "ワーカーは後始末されている" "$(live)" 0

# ---------------------------------------------------------------- 15
banner "15. キューが読めないとき黙って素通りしない（TCC 対策）"
reset_sandbox
echo 'should not be silently ignored' > "$Q/blocked.txt"
chmod 000 "$Q"
sweep
rc_dir_readable=$?
chmod 755 "$Q"
check "エラーとして記録される"     "$(grep -c 'キューを読めない' "$DTQ_LOG_FILE")" 1
check "対処方法も記録される"       "$(grep -c '署名済み app バンドル' "$DTQ_LOG_FILE")" 1
check "構造化ログにも残る"         "$(grep -c 'queue_unreadable' "$DTQ_JSONL_FILE")" 1
check "ワーカーは落ちない"         "$rc_dir_readable" 0
check "誤って failed にはしない"   "$(nfiles "$FL")" 0

# 権限が戻れば通常どおり処理される
sweep
check "読めるようになれば処理される" "$(nfiles "$SB/images")" 1
check "回復後は警告を繰り返さない"   "$(grep -c 'キューを読めない' "$DTQ_LOG_FILE")" 1

# ---------------------------------------------------------------- 16
banner "16. 異常に遅い生成を記録する（許可ダイアログ待ちの検知）"
reset_sandbox
export DTQ_SLOW_GEN_WARN=-1   # 所要0秒でも「遅い」と見なす
echo 'slow generation probe' > "$Q/slow.txt"
sweep
check "生成自体は成功する"       "$(nfiles "$SB/images")" 1
check "遅延が警告として残る"     "$(grep -c 'WARN.*生成に' "$DTQ_LOG_FILE")" 1
check "構造化ログにも残る"       "$(grep -c 'slow_generation' "$DTQ_JSONL_FILE")" 1

reset_sandbox
echo 'normal speed probe' > "$Q/fast.txt"
sweep
check "通常速度なら警告しない"   "$(grep -c 'WARN.*生成に' "$DTQ_LOG_FILE")" 0

# ---------------------------------------------------------------- 17
banner "17. モデルが取り込まれていなければ即座に失敗する"
reset_sandbox
rm -f "$SB/models/z_image_turbo_1.0_q8p.ckpt"
echo 'no models available' > "$Q/nomodel.txt"
sweep
check "CLI を呼ばない"           "$(grep -c '^--- invocation ---$' "$DTQ_FAKE_LOG")" 0
check "failed に落ちる"          "$(nfiles "$FL" '*.error.json')" 1
err="$(find "$FL" -name '*.error.json' | head -1)"
check "error_kind=models_missing" "$(jq -r .error_kind "$err")" "models_missing"
check "対処法が示される"          "$(jq -r .message "$err" | grep -c 'dtq-setup')" 1
check "リトライしない"            "$(jq -r .attempts "$err")" "0"

# ---------------------------------------------------------------- 18
banner "18. 取り込み失敗は一過性として扱う（iCloud のロック対策）"
reset_sandbox
mkdir -p "$SB/state/work/incoming"
chmod 000 "$SB/state/work/incoming"    # mv を必ず失敗させる
echo 'intake will fail at first' > "$Q/locked.txt"

sweep
check "持ち越される"              "$(nfiles "$Q" '*.txt')" 1
check "  ERROR にはしない"        "$(grep -c 'ERROR:' "$DTQ_LOG_FILE")" 0
check "  failed には落とさない"   "$(nfiles "$FL")" 0
sweep; sweep
check "何度スイープしても持ち越す" "$(nfiles "$Q" '*.txt')" 1

export DTQ_INTAKE_DEADLINE=0
sweep
check "期限を過ぎたら失敗させる"  "$(grep -c 'ERROR:.*取り込めない' "$DTQ_LOG_FILE")" 1
err="$(find "$FL" -name '*.error.json' | head -1)"
check "  実際のエラーを残す"      "$(jq -r .message "$err" | grep -ci 'permission\|denied\|not permitted')" 1

chmod 755 "$SB/state/work/incoming"
export DTQ_INTAKE_DEADLINE=900
echo 'now it works' > "$Q/recovered.txt"
sweep
check "回復後は正常に処理される"   "$(nfiles "$SB/images")" 1

# ---------------------------------------------------------------- 19
banner "19. 同期途中の空ファイルを処理してしまわない（iPhone 実機で発生）"
reset_sandbox
: > "$Q/arriving.txt"                  # iCloud 同期途中の 0 バイト状態
sweep
check "空のうちは取り込まない"      "$(nfiles "$Q" '*.txt')" 1
check "  ジョブにしない"            "$(nfiles "$PEND")" 0
check "  画像も作らない"            "$(nfiles "$SB/images")" 0
check "  failed にも落とさない"     "$(nfiles "$FL")" 0
check "  待機として記録する"        "$(grep -c '中身がまだ空' "$DTQ_LOG_FILE")" 1

echo 'the content finally arrived' > "$Q/arriving.txt"   # 同期完了
sweep
check "中身が届いたら処理される"    "$(nfiles "$SB/images")" 1
check "  queue から消える"          "$(nfiles "$Q" '*.txt')" 0
check "  プロンプトは届いた内容"    "$(grep -c 'the content finally arrived' "$DTQ_FAKE_LOG")" 1

# ---------------------------------------------------------------- 20
banner "20. seed:-1 はランダム指定として受け付ける（他ツールの慣習）"
reset_sandbox
printf '{"prompt":"random seed probe","seed":-1,"count":2}' > "$Q/rand.json"
sweep
check "検証を通る"          "$(nfiles "$FL")" 0
check "2枚生成される"       "$(nfiles "$SB/images")" 2
check "seed は負値でない"   "$(jq -rs '[.[].seed]|map(select(.<0))|length' $(find "$RS" -name '*.json'))" 0
check "2つとも別の seed"    "$(jq -rs '[.[].seed]|unique|length' $(find "$RS" -name '*.json'))" 2

# ---------------------------------------------------------------- 21
banner "21. バッチ処理中でもキューを見続ける（検知遅延の保証）"
reset_sandbox
# 1件目の生成中に、2件目がキューへ届く状況を作る
export DTQ_FAKE_DROP="$Q/arrived-mid-batch.txt"
printf 'first job\nsecond job\n' > "$Q/batch.txt"
sweep
check "元の2件は生成された"           "$(( $(nfiles "$SB/images") >= 2 ? 2 : $(nfiles "$SB/images") ))" 2
check "処理中に届いた分も同じ回で拾う" "$(grep -c 'dropped while a batch was running' "$DTQ_FAKE_LOG")" 1
check "合計3枚"                        "$(nfiles "$SB/images")" 3
check "queue は空になる"               "$(nfiles "$Q" '*.txt')" 0
check "failed は出ない"                "$(nfiles "$FL")" 0

# ---------------------------------------------------------------- 22
banner "22. 拡張子ではなく中身で JSON を判定する（ショートカット対策）"
reset_sandbox
# iOS ショートカットは JSON を書いても .txt として保存することがある
cat > "$Q/command.txt" <<'JSON'
{
  "title": "shortcut",
  "prompt": "saved as txt but the content is json",
  "seed": 555,
  "count": 2
}
JSON
sweep
check ".txt でも JSON として解釈する"   "$(nfiles "$SB/images")" 2
check "  seed が 555,556 になる"        "$(jq -rs '[.[].seed]|sort|join(",")' $(find "$RS" -name '*.json'))" "555,556"
check "  行ごとの生成をしていない"      "$(grep -c '"title"' "$DTQ_FAKE_LOG")" 0
check "  failed は出ない"               "$(nfiles "$FL")" 0

banner "22b. JSON のつもりで壊れていたら、行ごとに処理せず止める"
reset_sandbox
printf '{\n  "prompt": "truncated json in a txt file",\n  "seed": 1\n' > "$Q/broken.txt"
export DTQ_PARSE_DEADLINE=0
sweep
check "画像を作らない"                 "$(nfiles "$SB/images")" 0
check "CLI を呼ばない"                 "$(grep -c '^--- invocation ---$' "$DTQ_FAKE_LOG")" 0
check "failed に落ちる"                "$(nfiles "$FL" '*.error.json')" 1
export DTQ_PARSE_DEADLINE=180

banner "22c. 通常の .txt は従来どおり1行1プロンプト"
reset_sandbox
printf 'first line prompt\nsecond line prompt\n' > "$Q/plain.txt"
sweep
check "2枚生成される"                  "$(nfiles "$SB/images")" 2

banner "22d. count の上限は 200"
reset_sandbox
printf '{"prompt":"many","seed":1,"count":200}' > "$Q/many.json"
sweep
check "200 は通る"                     "$(nfiles "$SB/images")" 200
reset_sandbox
printf '{"prompt":"too many","seed":1,"count":201}' > "$Q/toomany.json"
sweep
check "201 は弾く"                     "$(jq -r .error_kind "$(find "$FL" -name '*.error.json'|head -1)")" "out_of_range"

# ---------------------------------------------------------------- 結果
banner "結果"
printf '  成功 %d / 失敗 %d\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
