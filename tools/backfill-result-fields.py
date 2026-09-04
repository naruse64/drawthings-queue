#!/usr/bin/env python3
"""既存の result.json に sha256 / model / schema_version を後追いで足す。使い捨て。

生成時に記録されなかった項目を、あとから埋める。

  sha256          images[].path のファイルを実際にハッシュする。観測値。
  model           生成時の記録が無いため、引数で渡された値を書く。推測値。
                  そうと分かるよう backfilled: true を付ける。
  schema_version  上2つを埋めた時点で v1 の構成になるため付ける。

既定は dry-run。--apply を付けたときだけ書き込む。書き込みは一時ファイル経由の
os.replace で原子的に行う。既に値がある項目は触らない（再実行しても安全）。
"""
import argparse
import hashlib
import json
import os
import sys


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir")
    ap.add_argument("--model", default=None,
                    help="生成に使ったモデルのファイル名。省略すると model は埋めない")
    ap.add_argument("--images-dir", default=None,
                    help="陳腐化したパスの探索先。同名のファイルがあれば path を直す")
    ap.add_argument("--drop-orphans", action="store_true",
                    help="画像が1枚も現存しない記録を削除する")
    ap.add_argument("--apply", action="store_true", help="実際に書き込む（既定は dry-run）")
    args = ap.parse_args()

    files = sorted(f for f in os.listdir(args.results_dir) if f.endswith(".result.json"))
    stat = {
        "対象": len(files), "更新": 0, "変更不要": 0, "読めない": 0,
        "sha256 追加": 0, "画像が無い": 0, "model 追加": 0, "schema_version 追加": 0,
        "パス修復": 0, "孤児を削除": 0,
    }
    missing_examples, broken_examples, orphans = [], [], []

    for name in files:
        path = os.path.join(args.results_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                doc = json.load(fh)
        except Exception as exc:
            stat["読めない"] += 1
            if len(broken_examples) < 3:
                broken_examples.append("%s: %s" % (name, exc))
            continue

        changed = False

        for img in doc.get("images") or []:
            if img.get("sha256"):
                continue
            p = img.get("path")
            # 画像の保存先を移すと、記録された絶対パスが陳腐化する。
            # 同名のファイルが現在の保存先にあれば、それを指すよう直す。
            # ファイル名に seed と生成日時が入っているので、同名は同一とみなせる。
            if p and not os.path.isfile(p) and args.images_dir:
                alt = os.path.join(args.images_dir, os.path.basename(p))
                if os.path.isfile(alt):
                    img["path"] = p = alt
                    stat["パス修復"] += 1
                    changed = True
            if not p or not os.path.isfile(p):
                stat["画像が無い"] += 1
                if len(missing_examples) < 3:
                    missing_examples.append(p or "(path なし)")
                continue
            try:
                img["sha256"] = sha256_of(p)
            except Exception:
                stat["画像が無い"] += 1
                continue
            stat["sha256 追加"] += 1
            changed = True

        # 画像が1枚も残っていない記録。sha256 を付けようがないので、契約どおりの
        # 形にならない。消したい場合だけ落とす。
        imgs = doc.get("images") or []
        if imgs and not any(os.path.isfile(i.get("path") or "") for i in imgs):
            orphans.append((path, name))
            continue

        if args.model and not doc.get("model"):
            # 生成時の記録ではなく、あとから当てた値。区別できるようにする。
            doc["model"] = {"file": args.model, "backfilled": True}
            stat["model 追加"] += 1
            changed = True

        if "schema_version" not in doc:
            doc["schema_version"] = 1
            stat["schema_version 追加"] += 1
            changed = True

        if not changed:
            stat["変更不要"] += 1
            continue
        stat["更新"] += 1

        if args.apply:
            tmp = path + ".backfill.tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(doc, fh, ensure_ascii=False, indent=2)
            os.replace(tmp, path)

    for path, name in orphans:
        stat["孤児を削除" if args.drop_orphans else "画像が無い"] += 1
        if args.drop_orphans and args.apply:
            os.remove(path)

    print("=== %s ===" % ("適用" if args.apply else "dry-run（書き込みなし）"))
    for k, v in stat.items():
        print("  %-16s %d" % (k, v))
    if orphans:
        print("\n画像が1枚も現存しない記録（%s）:" % ("削除対象" if args.drop_orphans else "残す"))
        for _, n in orphans:
            print("  " + n)
    if missing_examples:
        print("\n画像が見つからなかった例:")
        for p in missing_examples:
            print("  " + p)
    if broken_examples:
        print("\n読めなかった例:")
        for p in broken_examples:
            print("  " + p)
    if not args.apply and (stat["更新"] or stat["孤児を削除"]):
        print("\n書き込むには --apply を付けて再実行する。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
