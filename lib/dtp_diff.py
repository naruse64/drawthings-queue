#!/usr/bin/env python3
"""生成画像2枚の画素差を測る。

なぜ必要か: 同一プロンプト・同一シードでも画像はビット一致しない（findings.md D-2）。
GPU の浮動小数点の畳み込み順序が実行ごとに変わるため、画素の 85% が相違する。
ただし平均絶対差は 4.85/255 で見た目は区別できない。

したがって「プロンプトを変えたら絵が変わった」だけでは何も言えない。
この 4.85 を下限として、変化がその何倍かで判定する。

PNG のデコードには sips（macOS 標準）を使う。無圧縮 TIFF に変換すると
末尾が生の RGB になるので、そこを比較する。
"""
import os
import subprocess
import sys
import tempfile

# 同一プロンプト・同一シードを2回実行したときの平均絶対差（D-2）。
# これ以下の差は「変わっていない」と読む。
NOISE_FLOOR = 4.85

# 全画素を舐めると Python では遅い。素数間隔で間引いて偏りを避ける。
SAMPLE_STRIDE = 7


def to_raw(png_path, tmpdir):
    """PNG を無圧縮 TIFF に変換し、生の画素バイトと (幅, 高さ) を返す。"""
    out = os.path.join(tmpdir, os.path.basename(png_path) + ".tiff")
    r = subprocess.run(
        ["sips", "-s", "format", "tiff", "-s", "formatOptions", "none",
         png_path, "--out", out],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    if r.returncode != 0:
        raise RuntimeError("sips が失敗した: %s" % png_path)

    dims = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", png_path],
        capture_output=True, text=True,
    ).stdout
    w = h = None
    for line in dims.splitlines():
        line = line.strip()
        if line.startswith("pixelWidth:"):
            w = int(line.split(":")[1])
        elif line.startswith("pixelHeight:"):
            h = int(line.split(":")[1])
    if not w or not h:
        raise RuntimeError("画像サイズを取得できない: %s" % png_path)

    data = open(out, "rb").read()
    n = w * h * 3
    if len(data) < n:
        raise RuntimeError("画素データが足りない: %s" % png_path)
    return data[-n:], (w, h)


def compare(png_a, png_b):
    """平均絶対差と、差が 16 を超えたバイトの割合を返す。"""
    with tempfile.TemporaryDirectory() as tmp:
        a, dim_a = to_raw(png_a, tmp)
        b, dim_b = to_raw(png_b, tmp)
    if dim_a != dim_b:
        raise RuntimeError("画像サイズが違う: %s vs %s" % (dim_a, dim_b))

    total = big = count = 0
    for i in range(0, len(a), SAMPLE_STRIDE):
        d = a[i] - b[i]
        if d < 0:
            d = -d
        total += d
        if d > 16:
            big += 1
        count += 1
    return total / count, 100.0 * big / count


def verdict(mean):
    """ノイズ下限に対する倍率から、変化の読み方を返す。"""
    ratio = mean / NOISE_FLOOR
    if ratio < 1.5:
        return ratio, "変化なし（実行ごとのゆらぎと区別できない）"
    if ratio < 4:
        return ratio, "わずかな変化"
    if ratio < 10:
        return ratio, "明確な変化"
    return ratio, "大きな変化"


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: dtp_diff.py <a.png> <b.png>\n")
        return 2
    try:
        mean, big = compare(sys.argv[1], sys.argv[2])
    except RuntimeError as exc:
        sys.stderr.write("エラー: %s\n" % exc)
        return 2
    ratio, note = verdict(mean)
    print("平均絶対差 %6.2f / 255   差>16 %5.2f%%   ノイズ比 %5.1f倍   %s"
          % (mean, big, ratio, note))
    return 0


if __name__ == "__main__":
    sys.exit(main())
