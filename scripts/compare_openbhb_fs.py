#!/usr/bin/env python3
"""OpenBHB が公開している FreeSurfer の ROI 特徴量と、自分で実行した recon-all の結果を比べる。

公開データ: <DATA_ROOT>/<split>/derivatives/sub-*/ses-1/sub-*_preproc-freesurfer_desc-{desikan,destrieux}_ROI.npy
            shape (1, 7, n_roi)。7 チャンネルは ?h.aparc(.a2009s).stats の次の列に対応する:
              SurfArea, GrayVol, ThickAvg, ThickStd, MeanCurv, GausCurv, CurvInd
自分の結果: <OUTPUT_ROOT>/openBHB/<split>/freesurfer_<ver>/sub-*/stats/?h.aparc.stats, ?h.aparc.a2009s.stats

使い方:
  python3 scripts/compare_openbhb_fs.py [--split val] [--versions 6.0 7.4.1 8.2.0] [--out reports/openbhb_<split>_vs_published_freesurfer]
出力 (--out):
  summary.md                まとめ (Markdown) (チャンネル別の一致度、バージョン比較、サイト別、外れ値)
  roi_metrics.tsv           バージョン x アトラス x チャンネル x ROI ごとの一致度
  subject_metrics.tsv       バージョン x 被験者ごとの一致度 (Desikan 平均厚さ等)
  global_metrics.tsv        全脳の指標 (総表面積、総灰白質体積、平均厚さ) の被験者ごとの値
numpy だけで動く (pandas / scipy 不要)。
"""
import argparse
import csv
import os
import sys
from collections import defaultdict

import numpy as np

CHANNELS = ["surface_area_mm^2", "gray_matter_volume_mm^3", "average_thickness_mm", "thickness_stddev_mm",
            "integrated_rectified_mean_curvature_mm^-1", "integrated_rectified_gaussian_curvature_mm^-2",
            "intrinsic_curvature_index"]
SHORT = ["area", "volume", "thickness", "thick_std", "mean_curv", "gaus_curv", "curv_ind"]
STATS_COLS = ["SurfArea", "GrayVol", "ThickAvg", "ThickStd", "MeanCurv", "GausCurv", "CurvInd"]
ATLASES = {"desikan": "aparc", "destrieux": "aparc.a2009s"}


def read_labels(path):
    with open(path) as f:
        return [l.strip() for l in f if l.strip()]


def read_stats(path):
    """?h.<annot>.stats -> {StructName: [7 values]}"""
    out, cols = {}, None
    with open(path) as f:
        for line in f:
            if line.startswith("# ColHeaders"):
                cols = line.split()[2:]
                continue
            if line.startswith("#") or not line.strip():
                continue
            v = line.split()
            # FreeSurfer 6.0 の Destrieux は "G&S_..."、7 以降と公開データは "G_and_S_..."
            out[v[0].replace("&", "_and_")] = [float(v[cols.index(c)]) for c in STATS_COLS]
    return out


def is_done(sd):
    sc = os.path.join(sd, "scripts")
    d, e = os.path.join(sc, "recon-all.done"), os.path.join(sc, "recon-all.error")
    if not os.path.isfile(d):
        return False
    with open(d, errors="replace") as f:
        if not any(l.startswith("END_TIME") for l in f):
            return False
    return not os.path.isfile(e) or os.path.getmtime(d) > os.path.getmtime(e)


def load_ours(sd, atlas, labels):
    arr = np.full((7, len(labels)), np.nan)
    per_hemi = {}
    for h in ("lh", "rh"):
        p = os.path.join(sd, "stats", f"{h}.{ATLASES[atlas]}.stats")
        if not os.path.isfile(p):
            return None
        per_hemi[h] = read_stats(p)
    for i, lab in enumerate(labels):
        h, name = lab.split("-", 1)
        if name in per_hemi[h]:
            arr[:, i] = per_hemi[h][name]
    return arr


def icc_a1(x, y):
    """ICC(A,1): 2-way, absolute agreement, single measure (McGraw & Wong)。x, y: (n,)"""
    m = np.isfinite(x) & np.isfinite(y)
    d = np.stack([x[m], y[m]], 1)
    n, k = d.shape
    if n < 3:
        return np.nan
    gm = d.mean()
    msr = k * ((d.mean(1) - gm) ** 2).sum() / (n - 1)
    msc = n * ((d.mean(0) - gm) ** 2).sum() / (k - 1)
    sse = ((d - d.mean(1, keepdims=True) - d.mean(0, keepdims=True) + gm) ** 2).sum()
    mse = sse / ((n - 1) * (k - 1))
    den = msr + (k - 1) * mse + k * (msc - mse) / n
    return (msr - mse) / den if den > 0 else np.nan


def pearson(x, y):
    m = np.isfinite(x) & np.isfinite(y)
    if m.sum() < 3 or np.std(x[m]) == 0 or np.std(y[m]) == 0:
        return np.nan
    return float(np.corrcoef(x[m], y[m])[0, 1])


def med(a):
    a = np.asarray(a, float)
    return float(np.nanmedian(a)) if np.isfinite(a).any() else np.nan


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", default="val")
    ap.add_argument("--versions", nargs="+", default=["6.0", "7.4.1", "8.2.0"])
    ap.add_argument("--data-root", default="/raid/hirakawa/datasets/openBHB")
    ap.add_argument("--output-root", default="/raid/hirakawa/fs_output")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    out = a.out or f"reports/openbhb_{a.split}_vs_published_freesurfer"
    os.makedirs(out, exist_ok=True)

    deriv = os.path.join(a.data_root, a.split, "derivatives")
    labels = {k: read_labels(os.path.join(a.data_root, "resource", f"freesurfer_atlas-{k}_labels.txt")) for k in ATLASES}

    # participants (site)
    site = {}
    with open(os.path.join(a.data_root, "participants.tsv")) as f:
        r = csv.DictReader(f, delimiter="\t")
        for row in r:
            pid = row["participant_id"]
            pid = pid if pid.startswith("sub-") else "sub-" + pid.split(".")[0]
            site[pid] = row["site"].split(".")[0]

    subs = sorted(d for d in os.listdir(deriv) if d.startswith("sub-"))
    ref = {k: {} for k in ATLASES}
    for s in subs:
        for k in ATLASES:
            p = os.path.join(deriv, s, "ses-1", f"{s}_preproc-freesurfer_desc-{k}_ROI.npy")
            if os.path.isfile(p):
                ref[k][s] = np.load(p)[0]

    ours = {v: {k: {} for k in ATLASES} for v in a.versions}
    for v in a.versions:
        sdir = os.path.join(a.output_root, "openBHB", a.split, f"freesurfer_{v}")
        for s in subs:
            sd = os.path.join(sdir, s)
            if not is_done(sd):
                continue
            for k in ATLASES:
                arr = load_ours(sd, k, labels[k])
                if arr is not None:
                    ours[v][k][s] = arr
        print(f"{v}: done = {len(ours[v]['desikan'])}", file=sys.stderr)

    common = sorted(set(ref["desikan"]).intersection(*[ours[v]["desikan"] for v in a.versions]))

    def row(*cells):
        return "| " + " | ".join(str(c) for c in cells) + " |"

    def sep(spec):
        # spec: 各列の揃え ("l" or "r")
        return "|" + "|".join("---" if s == "l" else "---:" for s in spec) + "|"

    lines = []
    P = lines.append
    P(f"# OpenBHB {a.split}: 公開 FreeSurfer ROI 特徴量 と 自分の recon-all 結果の比較 (数値の詳細)")
    P("")
    P(f"このファイルは [`scripts/compare_openbhb_fs.py`](../../scripts/compare_openbhb_fs.py) が自動で作る。"
      "考察は [README.md](README.md) を参照。")
    P("")
    P(f"- 公開データ: `{deriv}/sub-*/ses-1/*_preproc-freesurfer_desc-{{desikan,destrieux}}_ROI.npy`")
    P(f"- 自分の結果: `{a.output_root}/openBHB/{a.split}/freesurfer_<ver>/sub-*/stats/?h.aparc(.a2009s).stats`")
    P(f"- 公開データの被験者数: {len(ref['desikan'])}")
    P("- 完了した被験者数: " + "、".join(f"{v} = {len(ours[v]['desikan'])}" for v in a.versions))
    P(f"- **比較に使った被験者: {len(common)} 人** (すべてのバージョンで完了し、公開データもある被験者)")
    P("")
    P("## 指標")
    P("")
    P("| 指標 | 意味 |")
    P("|---|---|")
    P("| r | 被験者間の Pearson 相関 (ROI ごとに計算し、ROI 間の中央値) |")
    P("| ICC | ICC(A,1) 絶対一致 (ROI ごと、中央値)。1 に近いほど値そのものが一致 |")
    P("| bias% | (自分 − 公開) / 公開 の平均 (ROI ごと、中央値)。正なら自分の方が大きい |")
    P("| \\|d\\|% | \\|自分 − 公開\\| / 公開 の平均 (ROI ごと、中央値) |")
    P("| exact% | 値が完全に一致した (被験者, ROI) の割合 (stats ファイルの丸め桁で比較) |")
    P("")

    roi_rows, subj_rows, glob_rows = [], [], []
    summary = defaultdict(dict)  # (v, atlas, ch) -> dict
    for v in a.versions:
        for k in ATLASES:
            R = np.stack([ref[k][s] for s in common])        # (n, 7, roi)
            O = np.stack([ours[v][k][s] for s in common])
            for c in range(7):
                rs, iccs, bias, apd = [], [], [], []
                for j, lab in enumerate(labels[k]):
                    x, y = O[:, c, j], R[:, c, j]
                    with np.errstate(divide="ignore", invalid="ignore"):
                        rel = (x - y) / np.abs(y)
                    rel[~np.isfinite(rel)] = np.nan
                    rr, ii = pearson(x, y), icc_a1(x, y)
                    b, ad = np.nanmean(rel) * 100, np.nanmean(np.abs(rel)) * 100
                    rs.append(rr); iccs.append(ii); bias.append(b); apd.append(ad)
                    roi_rows.append([v, k, SHORT[c], lab, f"{rr:.4f}", f"{ii:.4f}", f"{b:.3f}", f"{ad:.3f}",
                                     f"{np.nanmean(x):.4f}", f"{np.nanmean(y):.4f}"])
                exact = np.mean(np.isclose(O[:, c, :], R[:, c, :], rtol=0, atol=1e-9)) * 100
                summary[(v, k, SHORT[c])] = dict(r=med(rs), icc=med(iccs), bias=med(bias), apd=med(apd),
                                                  exact=exact, worst_roi=labels[k][int(np.nanargmin(iccs))],
                                                  worst_icc=float(np.nanmin(iccs)))

    P("## 1. チャンネル別の一致度")
    P("")
    for k in ATLASES:
        P(f"### {k.capitalize()} ({len(labels[k])} ROI)")
        P("")
        P(row("channel", "version", "r", "ICC", "bias%", "\\|d\\|%", "exact%", "最も一致しない ROI (ICC)"))
        P(sep("llrrrrrl"))
        for c in SHORT:
            for v in a.versions:
                m = summary[(v, k, c)]
                P(row(c, v, f"{m['r']:.3f}", f"{m['icc']:.3f}", f"{m['bias']:.2f}", f"{m['apd']:.2f}",
                      f"{m['exact']:.2f}", f"{m['worst_roi']} ({m['worst_icc']:.3f})"))
        P("")

    # ---- 全脳の指標 ----
    def glob(arr):
        area, vol, th = arr[0], arr[1], arr[2]
        tot_area = np.nansum(area)
        return tot_area, np.nansum(vol), np.nansum(th * area) / tot_area

    P("## 2. 全脳の指標")
    P("")
    P("Desikan 68 ROI の合計 (表面積・灰白質体積) と、面積で重み付けした平均厚さ。")
    P("")
    P(row("metric", "version", "r", "ICC", "bias%", "\\|d\\|%", "自分 (平均)", "公開 (平均)"))
    P(sep("llrrrrrr"))
    gnames = ["total_area_mm2", "total_gm_volume_mm3", "mean_thickness_mm"]
    G = {v: np.array([glob(ours[v]["desikan"][s]) for s in common]) for v in a.versions}
    GR = np.array([glob(ref["desikan"][s]) for s in common])
    for gi, gn in enumerate(gnames):
        for v in a.versions:
            x, y = G[v][:, gi], GR[:, gi]
            rel = (x - y) / y
            P(row(gn, v, f"{pearson(x, y):.3f}", f"{icc_a1(x, y):.3f}", f"{np.mean(rel) * 100:.2f}",
                  f"{np.mean(np.abs(rel)) * 100:.2f}", f"{x.mean():.2f}", f"{y.mean():.2f}"))
    for i, s in enumerate(common):
        glob_rows.append([s, site.get(s, "?")] + [f"{GR[i, g]:.4f}" for g in range(3)] +
                         [f"{G[v][i, g]:.4f}" for v in a.versions for g in range(3)])
    P("")

    # ---- バージョン同士の比較 ----
    P("## 3. バージョン同士の一致度 (参考)")
    P("")
    P("Desikan、ICC の ROI 中央値。公開データとの差が、バージョン間の差と比べてどの程度かの目安。")
    P("")
    pairs = [(a.versions[i], a.versions[j]) for i in range(len(a.versions)) for j in range(i + 1, len(a.versions))]
    P(row("channel", *[f"{p} vs {q}" for p, q in pairs], *[f"{v} vs 公開" for v in a.versions]))
    P(sep("l" + "r" * (len(pairs) + len(a.versions))))
    for c in range(7):
        vals = []
        for v1, v2 in pairs:
            X = np.stack([ours[v1]["desikan"][s][c] for s in common])
            Y = np.stack([ours[v2]["desikan"][s][c] for s in common])
            vals.append(med([icc_a1(X[:, j], Y[:, j]) for j in range(X.shape[1])]))
        P(row(SHORT[c], *[f"{x:.3f}" for x in vals],
              *[f"{summary[(v, 'desikan', SHORT[c])]['icc']:.3f}" for v in a.versions]))
    P("")

    # ---- 被験者ごと ----
    P("## 4. 被験者ごとの一致度")
    P("")
    P("Desikan の平均厚さについて、68 ROI の \\|d\\|% の平均 (被験者ごと) と、ROI 間の相関。")
    P("")
    P(row("version", "\\|d\\|% 中央値", "25%", "75%", "最大", "\\|d\\|% > 10 の人数", "ROI 間相関の中央値"))
    P(sep("lrrrrrr"))
    subj_apd = {}
    for v in a.versions:
        apds, rs = [], []
        for s in common:
            x, y = ours[v]["desikan"][s][2], ref["desikan"][s][2]
            ad = np.nanmean(np.abs(x - y) / y) * 100
            rr = pearson(x, y)
            ax, ay = ours[v]["desikan"][s][0], ref["desikan"][s][0]
            ada = np.nanmean(np.abs(ax - ay) / ay) * 100
            apds.append(ad); rs.append(rr)
            subj_apd[(v, s)] = ad
            subj_rows.append([v, s, site.get(s, "?"), f"{ad:.3f}", f"{rr:.4f}", f"{ada:.3f}"])
        apds = np.array(apds)
        P(row(v, f"{np.median(apds):.2f}", f"{np.percentile(apds, 25):.2f}", f"{np.percentile(apds, 75):.2f}",
              f"{apds.max():.2f}", int((apds > 10).sum()), f"{np.nanmedian(rs):.3f}"))
    P("")

    # ---- サイト別 ----
    P("## 5. サイト別")
    P("")
    P("Desikan 平均厚さの \\|d\\|% (被験者の中央値)。人数の多い順に上位 15 サイト。")
    P("")
    by_site = defaultdict(list)
    for s in common:
        by_site[site.get(s, "?")].append(s)
    P(row("site", "n", *a.versions))
    P(sep("r" * (2 + len(a.versions))))
    for st, ss in sorted(by_site.items(), key=lambda t: -len(t[1]))[:15]:
        P(row(st, len(ss), *[f"{np.median([subj_apd[(v, s)] for s in ss]):.2f}" for v in a.versions]))
    P("")
    worst = sorted(by_site.items(), key=lambda t: -np.median([subj_apd[(a.versions[0], s)] for s in t[1]]))[:5]
    P(f"差が大きいサイト ({a.versions[0]} の \\|d\\|% 中央値の大きい順): " +
      ", ".join(f"site {st} (n={len(ss)}, {np.median([subj_apd[(a.versions[0], s)] for s in ss]):.2f}%)" for st, ss in worst))
    P("")

    # ---- 外れ値 ----
    P("## 6. 公開データとの差が大きい被験者")
    P("")
    P("Desikan 平均厚さの \\|d\\|%。各バージョンの上位 10 人。")
    P("")
    P(row("順位", *a.versions))
    P(sep("r" + "l" * len(a.versions)))
    tops = {v: sorted(common, key=lambda s: -subj_apd[(v, s)])[:10] for v in a.versions}
    for i in range(10):
        P(row(i + 1, *[f"{tops[v][i]} (site {site.get(tops[v][i], '?')}, {subj_apd[(v, tops[v][i])]:.1f}%)"
                       for v in a.versions]))
    P("")

    # ---- 公開データにあるが自分の結果で完了していない被験者 ----
    P("## 7. 公開データには値があるが、自分の実行では完了していない被験者")
    P("")
    P(row("version", "人数", "site の内訳"))
    P(sep("lrl"))
    for v in a.versions:
        miss = sorted(set(ref["desikan"]) - set(ours[v]["desikan"]))
        cnt = defaultdict(int)
        for s in miss:
            cnt[site.get(s, "?")] += 1
        P(row(v, len(miss), ", ".join(f"site {k}: {n}" for k, n in sorted(cnt.items()))))
    P("")
    s38 = [s for s in ref["desikan"] if site.get(s) == "38"]
    if s38:
        def mth(s):
            return np.nansum(ref["desikan"][s][2] * ref["desikan"][s][0]) / np.nansum(ref["desikan"][s][0])
        th = np.array([mth(s) for s in s38])
        tho = np.array([mth(s) for s in ref["desikan"] if site.get(s) != "38"])
        P(f"参考: 公開データの site 38 ({len(s38)} 人) の平均厚さは {th.mean():.3f} mm (他サイトは {tho.mean():.3f} mm)。")
        P("")

    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out, "roi_metrics.tsv"), "w") as f:
        f.write("version\tatlas\tchannel\troi\tpearson_r\ticc_a1\tbias_pct\tabs_diff_pct\tmean_ours\tmean_published\n")
        f.writelines("\t".join(r) + "\n" for r in roi_rows)
    with open(os.path.join(out, "subject_metrics.tsv"), "w") as f:
        f.write("version\tsubject\tsite\tthickness_abs_diff_pct\tthickness_roi_corr\tarea_abs_diff_pct\n")
        f.writelines("\t".join(r) + "\n" for r in subj_rows)
    with open(os.path.join(out, "global_metrics.tsv"), "w") as f:
        f.write("subject\tsite\t" + "\t".join(f"published_{g}" for g in gnames) + "\t" +
                "\t".join(f"fs{v}_{g}" for v in a.versions for g in gnames) + "\n")
        f.writelines("\t".join(r) + "\n" for r in glob_rows)
    print(f"保存しました: {out}/summary.md, roi_metrics.tsv, subject_metrics.tsv, global_metrics.tsv", file=sys.stderr)


if __name__ == "__main__":
    main()
