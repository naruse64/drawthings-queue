#!/usr/bin/env python3
"""queue に投入された .txt / .json を検証し、正規化済みジョブに展開する。

exit 0 : 正常（skipped が含まれることはある）
exit 2 : 検証エラー。リトライしても直らないので failed/ に送る（§07）
"""
import argparse
import json
import os
import random
import re
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dtp_scene  # noqa: E402  （同じ lib/ に置いてある）

MAX_PROMPT = 2000
STEPS_RANGE = (1, 50)
DIM_RANGE = (512, 2048)
BATCH_RANGE = (1, 4)
# 留守中に何十枚も回すのが本来の用途。1枚90秒なので 200 で約5時間。
# 上限の実質的な制約は時間だけで、メモリもディスクも問題にならない（§06）。
COUNT_RANGE = (1, 200)
WEIGHT_RANGE = (0.1, 1.0)
SEED_MAX = 2 ** 31 - 1
DEFAULT_STEPS = 8

# 使用を許可する LoRA。別モデル向けの LoRA を誤って指定しても生成前に弾く。
#
# 実体は dtq-common.sh の DT_LORAS で、環境変数として渡ってくる。
# bash 側と二重管理すると必ずずれるため、ここでは既定値だけ持つ。
LORA_WHITELIST = set(
    line.strip()
    for line in os.environ.get("DTQ_LORA_WHITELIST", "").splitlines()
    if line.strip()
) or {"realisticsnapshotz_image_turbo_lora_f16.ckpt"}

ALLOWED_KEYS = {
    "title", "prompt", "negative_prompt", "seed", "steps",
    "width", "height", "batch", "count", "loras",
}


class Invalid(Exception):
    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind
        self.message = message


def slugify(text, maxlen=40):
    s = re.sub(r"[^a-zA-Z0-9]+", "-", (text or "").strip()).strip("-").lower()
    s = s[:maxlen].strip("-")
    return s or "untitled"


def want_int(value, field, lo, hi):
    if isinstance(value, bool) or not isinstance(value, int):
        raise Invalid("bad_type", "%s は整数で指定する（受け取った値: %r）" % (field, value))
    if not (lo <= value <= hi):
        raise Invalid("out_of_range", "%s は %d〜%d の範囲（受け取った値: %d）" % (field, lo, hi, value))
    return value


def want_str(value, field, maxlen):
    if not isinstance(value, str):
        raise Invalid("bad_type", "%s は文字列で指定する（受け取った値: %r）" % (field, value))
    if len(value) > maxlen:
        raise Invalid("too_long", "%s は %d 文字まで（受け取った値: %d 文字）" % (field, maxlen, len(value)))
    return value


# スロット名／パラメータ名＋コロンで始まる行。全角コロンも受ける。
SCENE_HEAD_RE = re.compile(
    r"^\s*(?:%s)\s*[:：]"
    % "|".join(re.escape(k) for k in dtp_scene.SLOT_ORDER + dtp_scene.PARAM_KEYS)
)


def looks_like_scene(text):
    """最初の内容行がスロット名で始まるか。# とその他の空行は読み飛ばす。"""
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        return bool(SCENE_HEAD_RE.match(stripped))
    return False


def read_raw_jobs(path, name):
    """入力ファイルを raw なジョブ辞書のリストにする。"""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except UnicodeDecodeError:
        raise Invalid("not_utf8", "UTF-8 として読めない。テキストとして保存し直す")

    # 形式は拡張子ではなく中身で決める。
    #
    # iOS ショートカットの「ファイルを保存」はテキストを .txt として保存するため、
    # JSON を書いても command.txt という名前で届くことがある。拡張子だけで
    # 判断すると、JSON の各行がプロンプトとして扱われ、"seed": -1, のような
    # 断片から画像を作り始めてしまう（実測: 無関係な画像を8枚生成した）。
    is_json_ext = name.lower().endswith(".json")
    looks_like_json = text.lstrip()[:1] in ("{", "[")

    if is_json_ext or looks_like_json:
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            if is_json_ext:
                raise Invalid("invalid_json", "JSON として解析できない: %s" % exc)
            # 中身は JSON のつもりなのに壊れている。1行ずつプロンプトとして
            # 処理すると無関係な画像を量産するので、ここで止める。
            raise Invalid(
                "looks_like_json",
                "JSON のように見えるが解析できない: %s"
                "（1行1プロンプトとして扱うと事故になるため中断した）" % exc,
            )
        if isinstance(data, dict):
            return [data]
        if isinstance(data, list):
            for i, item in enumerate(data):
                if not isinstance(item, dict):
                    raise Invalid("bad_type", "配列の %d 番目がオブジェクトでない" % i)
            return data
        raise Invalid("bad_type", "JSON のトップレベルはオブジェクトか配列にする")

    # シーン記述（`主題: …` のスロット形式）。
    #
    # 判定は「最初の内容行がスロット名＋コロン」だけ。ゆるく判定すると
    # 通常のプロンプトを巻き込むので、先頭1行に絞る。いったんシーンと
    # 判定したら、以降の行が壊れていてもエラーにする（1行1プロンプトへの
    # フォールバックはしない）。JSON と同じ fail-closed。
    if looks_like_scene(text):
        try:
            return [dtp_scene.scene_to_job(text)]
        except dtp_scene.Invalid as exc:
            raise Invalid("invalid_scene", "シーン記述として解析できない: %s" % exc.message)

    # それ以外は 1行1プロンプト。空行と # 始まりは無視（§04）
    jobs = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        jobs.append({"prompt": stripped})
    return jobs


def normalize(raw, index):
    unknown = sorted(set(raw) - ALLOWED_KEYS)
    if unknown:
        raise Invalid(
            "unknown_field",
            "ジョブ %d に未知のフィールド %s。使えるのは %s"
            % (index, ", ".join(unknown), ", ".join(sorted(ALLOWED_KEYS))),
        )

    if "prompt" not in raw:
        raise Invalid("missing_prompt", "ジョブ %d に prompt がない" % index)
    prompt = want_str(raw["prompt"], "prompt", MAX_PROMPT).strip()
    if not prompt:
        raise Invalid("missing_prompt", "ジョブ %d の prompt が空" % index)

    job = {
        "prompt": prompt,
        "title": slugify(raw["title"] if raw.get("title") else prompt),
        "negative_prompt": None,
        "steps": DEFAULT_STEPS,
        "width": None,
        "height": None,
        "batch": 1,
        "loras": [],
    }

    if raw.get("negative_prompt") is not None:
        job["negative_prompt"] = want_str(
            raw["negative_prompt"], "negative_prompt", MAX_PROMPT
        ).strip() or None

    if raw.get("steps") is not None:
        job["steps"] = want_int(raw["steps"], "steps", *STEPS_RANGE)
    if raw.get("batch") is not None:
        job["batch"] = want_int(raw["batch"], "batch", *BATCH_RANGE)

    has_w = raw.get("width") is not None
    has_h = raw.get("height") is not None
    if has_w != has_h:
        raise Invalid(
            "incomplete_size",
            "width と height は両方まとめて指定する（片方だけだと縦横比がモデル既定と食い違う）",
        )
    if has_w:
        for field in ("width", "height"):
            value = want_int(raw[field], field, *DIM_RANGE)
            if value % 64 != 0:
                raise Invalid("not_multiple_of_64", "%s は64の倍数にする（受け取った値: %d）" % (field, value))
            job[field] = value

    for lora in raw.get("loras") or []:
        if not isinstance(lora, dict):
            raise Invalid("bad_type", "loras の要素はオブジェクトにする")
        extra = sorted(set(lora) - {"file", "weight"})
        if extra:
            raise Invalid("unknown_field", "loras に未知のキー %s" % ", ".join(extra))
        name = lora.get("file")
        if name not in LORA_WHITELIST:
            raise Invalid(
                "lora_not_allowed",
                "LoRA '%s' は許可されていない。使えるのは: %s"
                % (name, ", ".join(sorted(LORA_WHITELIST))),
            )
        weight = lora.get("weight", 0.6)
        if isinstance(weight, bool) or not isinstance(weight, (int, float)):
            raise Invalid("bad_type", "lora の weight は数値で指定する")
        if not (WEIGHT_RANGE[0] <= float(weight) <= WEIGHT_RANGE[1]):
            raise Invalid(
                "out_of_range",
                "lora の weight は %.1f〜%.1f の範囲（受け取った値: %s）"
                % (WEIGHT_RANGE[0], WEIGHT_RANGE[1], weight),
            )
        job["loras"].append({"file": name, "weight": float(weight)})

    seed = None
    if raw.get("seed") is not None:
        # -1 は Automatic1111 / Stability Matrix 系で「ランダム」を意味する慣習。
        # 未指定と同じ扱いにする。
        value = want_int(raw["seed"], "seed", -1, SEED_MAX)
        seed = None if value == -1 else value
    count = 1
    if raw.get("count") is not None:
        count = want_int(raw["count"], "count", *COUNT_RANGE)

    return job, seed, count


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--src-name", required=True)
    ap.add_argument("--sha8", required=True)
    ap.add_argument("--mtime", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--ledger", required=True)
    args = ap.parse_args()

    try:
        raw_jobs = read_raw_jobs(args.src, args.src_name)
    except Invalid as exc:
        print(json.dumps({"ok": False, "error_kind": exc.kind, "message": exc.message}))
        return 2

    if not raw_jobs:
        print(json.dumps({"ok": False, "error_kind": "empty", "message": "実行できるジョブが1件もない"}))
        return 2

    expanded = []
    try:
        for index, raw in enumerate(raw_jobs):
            job, seed, count = normalize(raw, index)
            for i in range(count):
                # §04: seed 指定ありなら +1 ずつずらす。未指定なら1件ごとに独立した乱数。
                item = dict(job)
                item["seed"] = (seed + i) if seed is not None else random.randint(0, SEED_MAX)
                item["loras"] = [dict(l) for l in job["loras"]]
                expanded.append(item)
    except Invalid as exc:
        print(json.dumps({"ok": False, "error_kind": exc.kind, "message": exc.message}))
        return 2

    prefix = "%s-%s-%s" % (slugify(args.src_name), args.sha8, args.mtime)
    created, skipped = [], []
    now = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")

    for seq, item in enumerate(expanded):
        # §05: job_id に mtime を含めることで「意図的な再投入」と
        #      「iCloud がファイルを復活させた」を区別する。
        job_id = "%s-%03d" % (prefix, seq)
        if os.path.exists(os.path.join(args.ledger, job_id)):
            skipped.append(job_id)
            continue
        item["job_id"] = job_id
        item["source"] = args.src_name
        item["attempts"] = 0
        item["created_at"] = now
        target = os.path.join(args.outdir, job_id + ".job.json")
        tmp = target + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(item, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, target)
        created.append(job_id)

    print(json.dumps({"ok": True, "created": created, "skipped": skipped}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
