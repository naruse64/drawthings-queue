#!/usr/bin/env python3
"""シーン記述（日本語のスロット形式）を読み、プロンプト文字列に組み立てる。

翻訳も語彙置換もしない。日本語のまま出力する。
findings.md D 章の実測で、日本語がそのまま通ること、英語に置き換えても
改善しないことを確認したため（D-1, D-3）。

この道具の仕事は「書き忘れを潰す」ことに絞ってある。実測では、記述量を
増やす効果が言語を変える効果に匹敵した（D-3）。

exit 0 : 正常
exit 2 : 検証エラー
"""
import argparse
import json
import os
import re
import sys

# 出力順序。実測で良好だったプロンプト構造に合わせる（D-4）。
# 「場所→主題→動作→服装→光→雰囲気→カメラ→媒体」の順に1スロット1文で並べる。
SLOT_ORDER = ["場所", "主題", "動作", "服装", "光", "雰囲気", "カメラ", "媒体", "補足"]

REQUIRED_SLOTS = ["主題"]

# 欠けていると警告するスロット群と、実測した効果量（D-3）。
# 倍率は「その群を足したときの平均画素差がノイズ下限の何倍か」。
# 群ごとに測ったので、群ごとに報告する。
RECOMMENDED_GROUPS = [
    (["服装", "雰囲気"], "10.5倍", "構図が寄る。無いと全身の量産型ストック写真になる"),
    (["光", "カメラ", "媒体"], "11.9倍", "写真としての質が出る。無いと平坦な環境光のまま"),
]

# 生成パラメータ。スロットと混ざらないよう ASCII キーで分ける。
PARAM_KEYS = ["seed", "steps", "width", "height", "count", "negative"]

MAX_PROMPT = 2000
SEED_MAX = 2 ** 31 - 1
DEFAULT_STEPS = 8

# SD1.5 系の呪文トークン。Qwen3-VL には効かないか逆効果なので落とす。
SPELL_WORDS = [
    "masterpiece", "best quality", "high quality", "worst quality",
    "ultra detailed", "ultra-detailed", "highly detailed", "absurdres",
    "highres", "award winning", "award-winning", "8k", "4k uhd",
    "photorealistic:", "trending on artstation",
]

# (word:1.2) / [word] / {word} — 重み記法。このモデルは解釈しない。
WEIGHT_RE = re.compile(r"\([^()]{1,60}:\s*[0-9]*\.?[0-9]+\s*\)|\{[^{}]{1,60}\}|\[[^\[\]]{1,60}\]")


class Invalid(Exception):
    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind
        self.message = message


def parse_scene(text):
    """`キー: 値` の行を辞書にする。# 始まりと空行は無視する。"""
    slots, params = {}, {}
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # 全角コロンも受ける。iPhone の日本語入力では半角に切り替えるのが面倒なため。
        m = re.match(r"^([^:：]+)[:：]\s*(.*)$", line)
        if not m:
            raise Invalid("bad_line", "%d 行目が `キー: 値` の形になっていない: %s" % (lineno, line))
        key, value = m.group(1).strip(), m.group(2).strip()
        if not value:
            continue                      # 値が空なら未記入と同じ扱い
        if key in SLOT_ORDER:
            target, name = slots, key
        elif key.lower() in PARAM_KEYS:
            target, name = params, key.lower()
        else:
            # 未知のキーは黙って無視しない。タイプミスを見逃さないため（spec.md §02 と同じ方針）
            raise Invalid(
                "unknown_key",
                "%d 行目の `%s` は未知のキー。使えるのは %s と %s"
                % (lineno, key, "/".join(SLOT_ORDER), "/".join(PARAM_KEYS)),
            )
        if name in target:
            raise Invalid("duplicate_key", "%d 行目の `%s` が重複している" % (lineno, key))
        target[name] = value
    return slots, params


def compose(slots):
    """スロットを規定順に1文ずつ並べる。日本語のまま、語順だけを保証する。"""
    parts = []
    for name in SLOT_ORDER:
        value = slots.get(name)
        if not value:
            continue
        # 文末が句点でなければ補う。並べたときに文の切れ目が曖昧にならないようにする。
        if not value.endswith(("。", ".", "！", "？", "!", "?")):
            value += "。"
        parts.append(value)
    return "".join(parts)


def lint(slots, prompt):
    """errors, warnings を返す。errors があれば生成させない。"""
    errors, warnings = [], []

    for name in REQUIRED_SLOTS:
        if not slots.get(name):
            errors.append("`%s` は必須" % name)

    for names, effect, note in RECOMMENDED_GROUPS:
        missing = [n for n in names if not slots.get(n)]
        if missing:
            warnings.append(
                "未記入 %s — 実測では、この群を足すと画素差がノイズの %s になった。%s（D-3）"
                % ("/".join(missing), effect, note)
            )

    low = prompt.lower()
    hit = [w for w in SPELL_WORDS if w in low]
    if hit:
        errors.append(
            "SD1.5 系の呪文トークン: %s — このモデルのエンコーダ（Qwen3-VL）には"
            "効かないか逆効果。被写体・状況・光・構図を説明的に書く" % ", ".join(hit)
        )

    weights = WEIGHT_RE.findall(prompt)
    if weights:
        errors.append(
            "重み記法 %s — このモデルは解釈しない。強調したいなら言葉で詳しく書く"
            % ", ".join(weights[:3])
        )

    # タグ列の検出。組み立て後は句点が必ず付くので、スロットの生の値で見る。
    # 短い断片が並んでいたらタグ、という判断。普通の文なら1断片が長くなる。
    for name in SLOT_ORDER:
        value = slots.get(name)
        if not value or "。" in value:
            continue
        segs = [t.strip() for t in re.split(r"[,、]", value) if t.strip()]
        if len(segs) >= 5 and sum(len(t) for t in segs) / len(segs) < 12:
            warnings.append(
                "`%s` がタグ列に見える（%d 個の短い断片）。"
                "このモデルは自然な文章のほうが通る" % (name, len(segs))
            )

    if len(prompt) > MAX_PROMPT:
        errors.append("プロンプトが %d 文字。上限は %d" % (len(prompt), MAX_PROMPT))
    if not prompt:
        errors.append("プロンプトが空")

    return errors, warnings


def want_int(value, name, lo, hi):
    try:
        n = int(str(value).strip())
    except ValueError:
        raise Invalid("bad_type", "`%s` は整数で書く: %s" % (name, value))
    if not (lo <= n <= hi):
        raise Invalid("out_of_range", "`%s` は %d〜%d の範囲: %d" % (name, lo, hi, n))
    return n


def build_job(slots, params, prompt):
    """dtq の job JSON にする。キー名は dtq_parse.py の ALLOWED_KEYS に合わせる。"""
    job = {"prompt": prompt}
    if "seed" in params:
        job["seed"] = want_int(params["seed"], "seed", -1, SEED_MAX)
    job["steps"] = want_int(params.get("steps", DEFAULT_STEPS), "steps", 1, 50)
    if "width" in params or "height" in params:
        if not ("width" in params and "height" in params):
            raise Invalid("bad_dims", "width と height は両方セットで指定する")
        job["width"] = want_int(params["width"], "width", 512, 2048)
        job["height"] = want_int(params["height"], "height", 512, 2048)
    if "count" in params:
        job["count"] = want_int(params["count"], "count", 1, 200)
    if "negative" in params:
        job["negative_prompt"] = params["negative"]
    return job


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    slots, params = parse_scene(text)
    prompt = compose(slots)
    return slots, params, prompt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["compose", "lint", "job", "slots"])
    ap.add_argument("scene")
    ap.add_argument("--set", action="append", default=[],
                    help="スロットを上書きする（例: --set 光=柔らかい順光）")
    args = ap.parse_args()

    try:
        slots, params, _ = load(args.scene)
        for pair in args.set:
            key, _, value = pair.partition("=")
            key = key.strip()
            if key not in SLOT_ORDER:
                raise Invalid("unknown_key", "--set の `%s` は未知のスロット" % key)
            slots[key] = value.strip()
        prompt = compose(slots)
        errors, warnings = lint(slots, prompt)
    except Invalid as exc:
        sys.stderr.write("エラー: %s\n" % exc.message)
        return 2

    if args.mode == "slots":
        print(json.dumps(slots, ensure_ascii=False))
        return 0

    for w in warnings:
        sys.stderr.write("警告: %s\n" % w)
    for e in errors:
        sys.stderr.write("エラー: %s\n" % e)
    if errors:
        return 2

    if args.mode == "lint":
        sys.stderr.write("問題なし（%d 文字）\n" % len(prompt))
        return 0
    if args.mode == "compose":
        print(prompt)
        return 0
    if args.mode == "job":
        try:
            print(json.dumps(build_job(slots, params, prompt), ensure_ascii=False, indent=2))
        except Invalid as exc:
            sys.stderr.write("エラー: %s\n" % exc.message)
            return 2
        return 0


if __name__ == "__main__":
    sys.exit(main())
