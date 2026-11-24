# OpenBHB val: 公開 FreeSurfer 特徴量と自分の解析結果 (6.0 / 7.4.1 / 8.2.0) の比較

- 作成日: 2026-11-24
- 数値の詳細: [`summary.md`](summary.md) ([`scripts/compare_openbhb_fs.py`](../../scripts/compare_openbhb_fs.py) の出力)
- データ:
  - [`roi_metrics.tsv`](roi_metrics.tsv): バージョン × アトラス × チャンネル × ROI ごとの一致度
  - [`subject_metrics.tsv`](subject_metrics.tsv): バージョン × 被験者ごとの一致度 (Desikan の厚さ・面積)
  - [`global_metrics.tsv`](global_metrics.tsv): 全脳の指標 (総表面積、総灰白質体積、平均厚さ) の被験者ごとの値

## 要約

| | 6.0 | 7.4.1 | 8.2.0 |
|---|---:|---:|---:|
| 全脳の平均厚さのずれ (bias) | **+2.3%** | +0.04% | +0.26% |
| 総灰白質体積のずれ | +1.1% | +0.03% | **+2.4%** |
| 総表面積のずれ | −0.7% | −0.02% | +1.0% |
| ROI の厚さの ICC (Desikan) | 0.849 | **0.975** | 0.941 |
| ROI の厚さの差 (Desikan) | 3.1% | **1.2%** | 1.6% |
| 被験者ごとの厚さの差の最大 | 15.5% | 5.8% | 9.0% |

**公開データは FreeSurfer 7.4.1 の結果に最も近い。** 公開データと同じ傾向の値が欲しいなら 7.4.1 を使うのがよい。

## 比較したもの

| | ファイル |
|---|---|
| 公開データ | `derivatives/sub-*/ses-1/*_preproc-freesurfer_desc-{desikan,destrieux}_ROI.npy` (shape `(1, 7, ROI数)`)。7 チャンネル × Desikan 68 ROI / Destrieux 148 ROI |
| 自分の結果 | `stats/?h.aparc.stats` (Desikan)、`stats/?h.aparc.a2009s.stats` (Destrieux) |

チャンネルと stats ファイルの列の対応 (値を突き合わせて確認済み):

| 公開データのチャンネル | stats の列 |
|---|---|
| `surface_area_mm^2` | SurfArea |
| `gray_matter_volume_mm^3` | GrayVol |
| `average_thickness_mm` | ThickAvg |
| `thickness_stddev_mm` | ThickStd |
| `integrated_rectified_mean_curvature_mm^-1` | MeanCurv |
| `integrated_rectified_gaussian_curvature_mm^-2` | GausCurv |
| `intrinsic_curvature_index` | CurvInd |

- 対象は、3バージョンすべてで完了した 735 人 (val 757 人中)。
- FreeSurfer 6.0 では Destrieux の ROI 名が `G&S_...` になっているので、`G_and_S_...` に読み替えて比べた。
- xhemi (fsaverage 上の頂点ごとの厚さ・曲率、8 × 163842) は今回比べていない。

## 結論

### 1. 公開データは FreeSurfer 7.4.1 の結果に最も近い

- **全脳の指標**
  - 総表面積・総灰白質体積・平均厚さのすべてで ICC 0.993〜0.999。
  - 系統的なずれ (bias) は ±0.05% 以内。
  - 被験者ごとの差は平均 0.25〜0.38%。
- **ROI ごと (Desikan)**
  - 厚さ: ICC 0.975、差 1.2%
  - 表面積: ICC 0.977、差 2.0%
  - 体積: ICC 0.983、差 2.2%
  - bias はどのチャンネルもほぼ 0。
- ただし、値が完全に一致するのは約 1% だけなので、同じバージョン・同じ環境で処理した結果ではない。
- 系統的なずれがないことから、公開データは FreeSurfer 7 系 (7.4.1 に近いバージョン) で処理されたと推定している。公開データ側のバージョンは README に書かれておらず、確認できていない。
- 残りの差は、マイナーバージョンやビルド・OS の違いによる処理のゆらぎ程度と考えられる。

### 2. 6.0 は公開データとの差が最も大きく、系統的なずれがある

- 厚さが +2.3% (全脳の平均 2.56 mm に対して公開データは 2.50 mm)、体積が +1.1%、表面積が −0.7%。
- ROI ごとの厚さは ICC 0.849、差 3.1%。曲率の 3 チャンネル (mean_curv、gaus_curv、curv_ind) は ICC 0.73〜0.81 まで下がる。
- バージョン同士で比べても、6.0 は 7.4.1 / 8.2.0 から離れている (厚さの ICC: 6.0 vs 7.4.1 = 0.857、7.4.1 vs 8.2.0 = 0.944)。
- FreeSurfer 6 と 7 で表面の作成処理が変わったことによる差と考えられる。

### 3. 8.2.0 は 7.4.1 と 6.0 の中間

- 厚さはほぼ一致する (bias +0.3%、ICC 0.941)。
- 一方で、体積 +2.4%・表面積 +1.0% の系統的なずれがある。
- 7.4.1 vs 8.2.0 (ICC 0.944) の差は、7.4.1 vs 公開データ (ICC 0.975) の差より大きい。

### 4. 一致しにくい ROI と指標

- 小さい ROI や表面の端にある ROI で、一致度が低い。
  - Desikan: entorhinal、frontalpole、insula、medialorbitofrontal、parahippocampal
  - Destrieux: G_subcallosal、G_insular_short、S_orbital_med-olfact、G_oc-temp_med-Parahip
- チャンネルごとに見ると、一致しやすい順に、厚さ・面積・体積 > 厚さの標準偏差 > 曲率 (mean_curv > gaus_curv > curv_ind)。
  - 曲率は丸めの桁が粗いので、完全一致の割合 (exact%) は高いが、ICC は低い。
- Destrieux は Desikan より ROI が小さいので、全体に一致度が少し低い (7.4.1 の厚さ: Desikan ICC 0.975、Destrieux ICC 0.967)。

### 5. 被験者・サイトごとの差

| version | 被験者ごとの厚さの差 (中央値) | 四分位 | 最大 | 差が大きいサイト |
|---|---:|---|---:|---|
| 6.0 | 3.2% | 2.6〜4.1% | 15.5% | site 41 (5.2%)、site 36 (4.2%)、site 45 |
| 7.4.1 | 1.2% | 1.0〜1.4% | 5.8% | ほぼ偏りなし (主要サイトで 0.9〜1.6%) |
| 8.2.0 | 1.9% | 1.6〜2.2% | 9.0% | site 36 の被験者が上位に多い |

- `sub-833420136477` (site 45) は 3バージョンすべてで差の上位に入っている (6.0: 12.0%、7.4.1: 5.8%、8.2.0: 8.6%)。画像か公開データ側に、この被験者固有の問題があるかもしれない。

### 6. site 38 について

- 公開データには site 38 の 21 人全員の値がある (平均厚さ 2.43 mm、他サイトは 2.50 mm)。
- 自分の実行では、site 38 の多くが前処理で失敗している ([解析失敗のまとめ](../openbhb_val_recon_failures/README.md) を参照)。OpenBHB 側は手作業で修正したか、別の前処理をした可能性がある (詳細は不明)。
- 自分の実行で完了した site 38 の被験者は、公開データとほぼ一致する。
  - 例: `sub-989798042528` の厚さの差は、7.4.1 で 0.9%、6.0 で 2.1%、8.2.0 で 3.5%。
  - 処理が通れば、結果は他のサイトと同じ程度に信頼できる。

## 実用上のまとめ

- 公開データと同じ傾向の値が欲しい場合 (公開データと混ぜて使う、公開データで学習したモデルに入力する、など) は 7.4.1 を使う。差は全脳で 0.4% 以下、ROI で 1〜2% 程度。
- 6.0 / 8.2.0 の値を公開データと混ぜる場合は、体積・厚さの系統的なずれ (数 %) に注意する。
- 曲率系の特徴量と小さい ROI は、どのバージョンでも公開データとの一致度が低い。

## 再実行の方法

```bash
python3 scripts/compare_openbhb_fs.py --split val --versions 6.0 7.4.1 8.2.0 \
    --out reports/openbhb_val_vs_published_freesurfer
```
