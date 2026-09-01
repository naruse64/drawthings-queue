#!/bin/bash
# dtp の単体テスト。draw-things-cli は呼ばないので実環境には触れない。
# 画素差の測定（dtp diff）は sips に依存するので、合成画像を作って確かめる。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DTP="$ROOT/bin/dtp"
SB="${DTP_TEST_SANDBOX:-/tmp/dtp-test-$$}"

PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期待=[$3] 実際=[$2]"; fi; }
banner(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# 標準エラーに指定の文字列が出るか。
# 先に出力を変数に取る。パイプで grep に渡すと pipefail のせいで
# dtp の exit 2 がパイプライン全体の戻り値になり、一致しても失敗と読まれる。
check_err() {
  local desc="$1" file="$2" want="$3" out
  out="$("$DTP" lint "$file" 2>&1)"
  if printf '%s\n' "$out" | grep -q "$want"; then ok "$desc"
  else bad "$desc" "「$want」が出なかった / 実際: $out"; fi
}

scene() { printf '%b' "$2" > "$SB/$1.txt"; printf '%s' "$SB/$1.txt"; }

rm -rf "$SB"; mkdir -p "$SB"
trap 'rm -rf "$SB"' EXIT

# ---------------------------------------------------------------- compose
banner "1. スロットを規定順に並べる"
f=$(scene order '媒体: フィルム写真\nカメラ: 中望遠\n主題: 女性\n場所: 喫茶店\n')
check "場所→主題→カメラ→媒体の順になる" \
  "$("$DTP" compose "$f" 2>/dev/null)" "喫茶店。女性。中望遠。フィルム写真。"

banner "2. 句点の補完"
f=$(scene period '主題: 女性\n場所: 喫茶店。\n')
check "無ければ足し、有れば足さない" \
  "$("$DTP" compose "$f" 2>/dev/null)" "喫茶店。女性。"

f=$(scene mark '主題: 誰だろう？\n')
check "？ も文末として扱う" "$("$DTP" compose "$f" 2>/dev/null)" "誰だろう？"

banner "2b. 文末記号は文字種で決める（英語に「。」を付けない）"
f=$(scene en '主題: Japanese 21 yo woman\n場所: Waikiki beach\nカメラ: cowboy shot\n')
check "英語は . で区切る" \
  "$("$DTP" compose "$f" 2>/dev/null)" "Waikiki beach. Japanese 21 yo woman. cowboy shot."

f=$(scene enperiod '主題: a woman.\n場所: a beach.\n')
check "既に . があれば足さず間だけ空ける" \
  "$("$DTP" compose "$f" 2>/dev/null)" "a beach. a woman."

f=$(scene mixed '主題: Japanese 21 yo woman\n場所: 夕方の喫茶店\n')
check "和英が混ざっても壊れない" \
  "$("$DTP" compose "$f" 2>/dev/null)" "夕方の喫茶店。Japanese 21 yo woman."

banner "3. コメントと空行と全角コロン"
f=$(scene fmt '# これはコメント\n\n主題： 女性\n場所:喫茶店\n')
check "# と空行を飛ばし、全角コロンも読む" \
  "$("$DTP" compose "$f" 2>/dev/null)" "喫茶店。女性。"

banner "4. 値が空の行は未記入と同じ"
f=$(scene empty '主題: 女性\n光:\n')
check "空値は出力に混ざらない" "$("$DTP" compose "$f" 2>/dev/null)" "女性。"

banner "5. --set でスロットを差し替える"
f=$(scene setslot '主題: 女性\n光: 逆光\n')
check "光だけ入れ替わる" \
  "$("$DTP" compose "$f" --set '光=順光' 2>/dev/null)" "女性。順光。"

# ---------------------------------------------------------------- lint
banner "6. 必須スロット"
f=$(scene noreq '場所: 喫茶店\n')
check_err "主題が無ければエラー" "$f" '`主題` は必須'
"$DTP" lint "$f" >/dev/null 2>&1; check "  exit=2" "$?" "2"

banner "7. 推奨スロットの警告は群ごとに出る"
f=$(scene warn '主題: 女性\n')
check_err "服装/雰囲気の群" "$f" '未記入 服装/雰囲気'
check_err "光/カメラ/媒体の群" "$f" '未記入 光/カメラ/媒体'
"$DTP" lint "$f" >/dev/null 2>&1; check "  警告だけなら exit=0" "$?" "0"

f=$(scene warn2 '主題: 女性\n服装: ニット\n光: 逆光\nカメラ: 中望遠\n媒体: フィルム\n')
check_err "埋まった分は警告に出ない" "$f" '未記入 雰囲気'
check "  光/カメラ/媒体は消える" \
  "$("$DTP" lint "$f" 2>&1 | grep -c '光/カメラ/媒体')" "0"

banner "8. SD1.5 の作法を弾く"
f=$(scene spell '主題: a woman, masterpiece, best quality\n')
check_err "呪文トークン" "$f" 'SD1.5 系の呪文トークン'
"$DTP" lint "$f" >/dev/null 2>&1; check "  exit=2" "$?" "2"

f=$(scene weight '主題: 女性\n光: (backlit:1.3) の逆光\n')
check_err "重み記法 (word:1.2)" "$f" '重み記法'

f=$(scene weight2 '主題: 女性\n光: {逆光}\n')
check_err "重み記法 {word}" "$f" '重み記法'

f=$(scene tags '主題: woman, cafe, window, knit, backlit, film, bokeh\n')
check_err "カンマ区切りのタグ列" "$f" 'タグ列に見える'

banner "9. タイプミスを黙って無視しない"
f=$(scene typo '主題: 女性\nカメラマン: 中望遠\n')
check_err "未知のキーはエラー" "$f" '未知のキー'

f=$(scene dup '主題: 女性\n主題: 男性\n')
check_err "キーの重複はエラー" "$f" '重複している'

f=$(scene noc '主題 女性\n')
check_err "コロンが無い行はエラー" "$f" 'の形になっていない'

banner "10. 長さの上限"
long=$(python3 -c 'print("あ"*2100)')
printf '主題: %s\n' "$long" > "$SB/long.txt"
check_err "2000文字超はエラー" "$SB/long.txt" '上限は 2000'

# ---------------------------------------------------------------- job
banner "11. dtq の job JSON にする"
f=$(scene job '主題: 女性\nseed: 424242\nsteps: 8\nwidth: 832\nheight: 1216\ncount: 3\n')
out="$("$DTP" job "$f" 2>/dev/null)"
check "prompt"  "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["prompt"])')" "女性。"
check "seed"    "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["seed"])')" "424242"
check "width"   "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["width"])')" "832"
check "count"   "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')" "3"

f=$(scene halfdim '主題: 女性\nwidth: 832\n')
"$DTP" job "$f" >/dev/null 2>&1; check "width だけだとエラー" "$?" "2"

f=$(scene badseed '主題: 女性\nseed: abc\n')
"$DTP" job "$f" >/dev/null 2>&1; check "seed が数値でなければエラー" "$?" "2"

f=$(scene bigcount '主題: 女性\ncount: 201\n')
"$DTP" job "$f" >/dev/null 2>&1; check "count 201 はエラー（dtq と同じ上限）" "$?" "2"

banner "12. job JSON が dtq の検証を通る"
f=$(scene forq '主題: 女性が座っている\n場所: 喫茶店\nseed: 1\n')
"$DTP" job "$f" 2>/dev/null > "$SB/j.json"
mkdir -p "$SB/out" "$SB/ledger"
DTQ_LORA_WHITELIST="" python3 "$ROOT/lib/dtq_parse.py" \
  --src "$SB/j.json" --src-name j.json --sha8 deadbeef --mtime 1 \
  --outdir "$SB/out" --ledger "$SB/ledger" >/dev/null 2>&1
check "dtq_parse.py が受理する" "$?" "0"
check "  ジョブが1件できる" "$(find "$SB/out" -name '*.job.json' | wc -l | tr -d ' ')" "1"

# ---------------------------------------------------------------- diff
banner "13. 画素差の測定"
# 同一画像・微差・大差の3枚を作る。sips が読める形式で用意する。
python3 - "$SB" <<'PY'
import struct, sys, zlib, os
sb = sys.argv[1]
W = H = 64
def png(path, shift):
    rows = b""
    for y in range(H):
        rows += b"\x00" + bytes(((x * 4 + shift) % 256) for x in range(W) for _ in range(3))
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(rows))
    out += chunk(b"IEND", b"")
    open(os.path.join(sb, path), "wb").write(out)
png("base.png", 0)
png("near.png", 2)      # 全画素が 2 ずれる → ノイズ相当
png("far.png", 90)      # 大きくずれる
PY

r="$("$DTP" diff "$SB/base.png" "$SB/base.png" 2>&1)"
check "同一画像は 0.00" "$(printf '%s' "$r" | grep -o '平均絶対差 *[0-9.]*' | grep -o '[0-9.]*$')" "0.00"
printf '%s' "$r" | grep -q '変化なし' && ok "  判定は「変化なし」" || bad "  判定は「変化なし」" "$r"

r="$("$DTP" diff "$SB/base.png" "$SB/near.png" 2>&1)"
printf '%s' "$r" | grep -q '変化なし' && ok "差 2 はノイズと区別できない" || bad "差 2 はノイズと区別できない" "$r"

r="$("$DTP" diff "$SB/base.png" "$SB/far.png" 2>&1)"
printf '%s' "$r" | grep -q '大きな変化' && ok "差 90 は「大きな変化」" || bad "差 90 は「大きな変化」" "$r"

banner "14. サイズ違いは比較しない"
python3 - "$SB" <<'PY'
import struct, sys, zlib, os
sb = sys.argv[1]
W, H = 32, 32
rows = b"".join(b"\x00" + bytes([128] * W * 3) for _ in range(H))
def chunk(tag, data):
    c = tag + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
out = b"\x89PNG\r\n\x1a\n"
out += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
out += chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(os.path.join(sb, "small.png"), "wb").write(out)
PY
"$DTP" diff "$SB/base.png" "$SB/small.png" >/dev/null 2>&1
check "サイズ違いはエラー" "$?" "2"

# ---------------------------------------------------------------- ab の引数
banner "15. ab は比較できない条件を先に弾く"
f=$(scene abnoseed '主題: 女性\n')
"$DTP" ab "$f" --slot 光 --variants a b >/dev/null 2>&1
check "seed が無ければエラー" "$?" "1"

f=$(scene abseed '主題: 女性\nseed: 1\n')
"$DTP" ab "$f" --slot 光 --variants a >/dev/null 2>&1
check "variants が1つならエラー" "$?" "1"

"$DTP" ab "$f" --variants a b >/dev/null 2>&1
check "--slot が無ければエラー" "$?" "1"

banner "15b. slots は CLI から呼べる"
f=$(scene slotsub '主題: 女性\n光: 逆光\n')
check "記入済みだけ JSON で返る" \
  "$("$DTP" slots "$f" 2>/dev/null)" '{"主題": "女性", "光": "逆光"}'

banner "16. ab を通しで動かす（CLI はスタブ）"
mkdir -p "$SB/out" "$SB/models"
export DTQ_CLI="$ROOT/test/fake-dt-cli-varying"
export DTQ_MODELS_DIR="$SB/models"
export DTP_OUT_DIR="$SB/out"
export DTP_FAKE_LOG="$SB/ab-calls.log"

f=$(scene abrun '主題: 女性が座っている\n場所: 喫茶店\nseed: 424242\nwidth: 512\nheight: 512\n')
r="$("$DTP" ab "$f" --slot 光 --variants "逆光" "順光" "斜光" 2>&1)"
check "3変種ぶん生成される" "$(find "$SB/out" -name 'ab-*.png' | wc -l | tr -d ' ')" "3"
check "CLI が3回呼ばれる"   "$(grep -c '^out=' "$DTP_FAKE_LOG")" "3"
check "全て同じ seed"       "$(grep -o 'seed=[0-9]*' "$DTP_FAKE_LOG" | sort -u | wc -l | tr -d ' ')" "1"
check "  seed はシーンの値" "$(grep -o 'seed=[0-9]*' "$DTP_FAKE_LOG" | sort -u)" "seed=424242"
check "幅・高さが渡る"      "$(grep -c 'w=512 h=512' "$DTP_FAKE_LOG")" "3"

check "変種の語がプロンプトに入る（逆光）" "$(grep -c 'prompt=.*逆光' "$DTP_FAKE_LOG")" "1"
check "  順光" "$(grep -c 'prompt=.*順光' "$DTP_FAKE_LOG")" "1"
check "  斜光" "$(grep -c 'prompt=.*斜光' "$DTP_FAKE_LOG")" "1"
check "共通部分は全変種に入る" "$(grep -c '喫茶店。女性が座っている。' "$DTP_FAKE_LOG")" "3"

# 3変種なら比較は 3 通り（0-1, 0-2, 1-2）
check "総当たりで比較する" "$(printf '%s\n' "$r" | grep -c 'vs \[')" "3"
printf '%s\n' "$r" | grep -q 'ノイズ比' && ok "  画素差が表示される" || bad "  画素差が表示される" "$r"

banner "17. ab は失敗を握り潰さない"
export DTQ_CLI="/bin/false"
"$DTP" ab "$f" --slot 光 --variants "逆光" "順光" >/dev/null 2>&1
check "生成に失敗したら止まる" "$?" "1"

export DTQ_CLI="$SB/nonexistent-cli"
"$DTP" ab "$f" --slot 光 --variants "逆光" "順光" >/dev/null 2>&1
check "CLI が無ければ生成前に止まる" "$?" "1"

# ---------------------------------------------------------------- 結果
banner "結果"
printf '  成功 %d / 失敗 %d\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
