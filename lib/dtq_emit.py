#!/usr/bin/env python3
"""JSON の組み立てと読み出し。

プロンプトには引用符・改行・日本語が入るため、シェルで JSON を文字列連結せず
すべてこのスクリプトを通す。

値の書き方:
  k=文字列          文字列として入れる
  k:=<JSONリテラル>  そのまま JSON として解釈する
  k:@<パス>         ファイルの中身を JSON として読み込む
"""
import json
import os
import sys
from datetime import datetime, timezone


def parse_kv(args):
    """`k=v` 形式を辞書にする。

    区切りは最も左に現れたものを採用する。こうしないと
    `prompt=a := b` のように値の中に他の区切りを含む文字列を取り違える。
    """
    out = {}
    for arg in args:
        found = [
            (pos, kind)
            for pos, kind in (
                (arg.find(":="), "raw"),
                (arg.find(":@"), "file"),
                (arg.find("="), "str"),
            )
            if pos >= 0
        ]
        if not found:
            raise SystemExit("不正な引数（区切りがない）: %s" % arg)
        pos, kind = min(found)
        key = arg[:pos]
        if kind == "raw":
            out[key] = json.loads(arg[pos + 2:])
        elif kind == "file":
            with open(arg[pos + 2:], "r", encoding="utf-8") as fh:
                out[key] = json.load(fh)
        else:
            out[key] = arg[pos + 1:]
    return out


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def write_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def main(argv):
    if not argv:
        raise SystemExit("サブコマンドが必要")
    cmd, rest = argv[0], argv[1:]

    if cmd == "event":
        obj = {"ts": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")}
        obj.update(parse_kv(rest))
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")

    elif cmd == "json":
        sys.stdout.write(json.dumps(parse_kv(rest), ensure_ascii=False, indent=2) + "\n")

    elif cmd == "field":
        value = load(rest[0]).get(rest[1])
        if value is None:
            return 0
        if isinstance(value, bool):
            sys.stdout.write("true" if value else "false")
        elif isinstance(value, (dict, list)):
            sys.stdout.write(json.dumps(value, ensure_ascii=False))
        else:
            sys.stdout.write(str(value))

    elif cmd == "images":
        # 標準入力の TSV（PNGパス <TAB> サムネイル相対パス）を
        # result JSON の images 配列にする。サムネイルは失敗すると空欄。
        items = []
        for line in sys.stdin.read().splitlines():
            if not line.strip():
                continue
            parts = line.split("\t")
            path = parts[0]
            thumb = parts[1] if len(parts) > 1 else ""
            sha = parts[2] if len(parts) > 2 else ""
            items.append({"path": path, "sha256": sha or None, "thumb": thumb or None})
        sys.stdout.write(json.dumps(items, ensure_ascii=False) + "\n")

    elif cmd == "config":
        # --config-json に渡す値。上書きが無ければ何も出さない
        # （§06: モデル推奨設定をそのまま活かす）。
        job = load(rest[0])
        cfg = {}
        if job.get("loras"):
            cfg["loras"] = job["loras"]
        if job.get("batch", 1) > 1:
            cfg["batchSize"] = job["batch"]
        if cfg:
            sys.stdout.write(json.dumps(cfg, ensure_ascii=False))

    elif cmd == "bump":
        # 実行試行回数を増減して書き戻し、新しい値を返す。
        # 停止指示による中断は「試した」うちに入れないので -1 で戻す。
        delta = int(rest[1]) if len(rest) > 1 else 1
        job = load(rest[0])
        job["attempts"] = max(0, int(job.get("attempts", 0)) + delta)
        write_atomic(rest[0], job)
        sys.stdout.write(str(job["attempts"]))

    elif cmd == "compose":
        # ジョブ定義の主要フィールドを引き継いだ result / error JSON を作る。
        job = load(rest[0])
        keys = ("job_id", "source", "title", "prompt", "negative_prompt",
                "seed", "steps", "width", "height", "batch", "loras", "attempts")
        obj = dict((k, job.get(k)) for k in keys)
        obj.update(parse_kv(rest[1:]))
        sys.stdout.write(json.dumps(obj, ensure_ascii=False, indent=2) + "\n")

    else:
        raise SystemExit("未知のサブコマンド: %s" % cmd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
