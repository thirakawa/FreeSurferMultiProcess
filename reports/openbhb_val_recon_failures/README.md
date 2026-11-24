# OpenBHB val: FreeSurfer 6.0 / 7.4.1 / 8.2.0 の解析失敗のまとめ

- 作成日: 2026-11-24
- 対象: `/raid/hirakawa/fs_output/openBHB/val/freesurfer_{6.0,7.4.1,8.2.0}`
- 判定: [`scripts/check_status.sh`](../../scripts/check_status.sh) と同じ基準
  (`recon-all.done` に `END_TIME` があり、それより新しい `recon-all.error` がない = 完了)
- 被験者ごとの状態の表: [`failure_status_by_version.tsv`](failure_status_by_version.tsv)
  (3バージョンすべてで完了しなかった 22 人 × バージョンごとの状態・ステップ・原因)

## 要約

- 失敗した 22 人のうち **21 人が site 38** (study 7, siteXacq 17)。
  site 38 は val に 21 人いて、3バージョンすべてで完了したのは `sub-989798042528` の 1 人だけ。
- 原因は site 38 の raw 画像そのもの。背景 (空気) が脳と同じくらい明るく、FreeSurfer の前処理
  (Talairach 位置合わせ、強度の正規化、頭蓋除去) が軒並み失敗する。
- site 38 以外で失敗したのは 2 人だけで、どちらも 1 つのバージョンだけでの失敗:
  - `sub-277976850330` (site 36): 8.2.0 の label-cortex
  - `sub-521804912208` (site 64): 6.0 の Fix Topology で 24h 時間切れ

## 1. 全体の結果 (val 757 人)

| バージョン | 完了 | 失敗 | 時間切れ / 停止 | 平均所要時間 (完了した被験者) |
|---|---:|---:|---|---:|
| 6.0 | 743 | 12 | 2 (24h 時間切れ) | 9.24h |
| 7.4.1 | 743 | 13 | 1 (Fix Topology で 30h 止まり、手動停止) | 6.5h |
| 8.2.0 | 738 | 14 | 5 (Fix Topology で止まり、手動停止) | 2.6〜2.9h |

3バージョンの完了パターン (1 = 完了、順に 6.0 / 7.4.1 / 8.2.0):

| パターン | 人数 | 内容 |
|---|---:|---|
| 111 | 735 | すべて完了 |
| 110 | 6 | 8.2.0 だけ失敗 |
| 101 | 1 | 7.4.1 だけ失敗 |
| 011 | 1 | 6.0 だけ時間切れ (`sub-521804912208`, site 64) |
| 100 | 1 | 6.0 だけ完了 |
| 010 | 1 | 7.4.1 だけ完了 |
| 001 | 1 | 8.2.0 だけ完了 |
| 000 | 11 | すべて失敗 |
| **計** | **757** | 3バージョンすべてでは完了しなかった人: 22 人 |

site 38 (val 21 人) のバージョン別の完了数: 6.0 が 8 人、7.4.1 が 7 人、8.2.0 が 3 人。3バージョンすべてで完了したのは 1 人。

## 2. 主な原因: site 38 の画像の特徴

site 38 の raw T1w (val 21 人すべて) には次の共通の特徴があり、他のサイトと大きく違う。

| 項目 | site 38 (21 人) | 他サイトの例 (5 人) |
|---|---|---|
| 画像サイズ | 176×240×256 (1mm) | 176×256×256 (1mm), 192×192×144 (1.2mm) など |
| 最大値 | 4079〜4089 | 619〜4095 |
| 非ゼロ画素の中央値 | 2054〜2189 | 12〜45 |
| 非ゼロ画素の割合 | 約 81〜84% | 約 63% |
| 背景 (画像の隅) の平均 | 約 1700 | 約 2 |
| 脳の中心付近の平均 | 約 1200〜2000 | 約 230 |

- 背景 (空気) がほぼ脳と同じ明るさで、脳と背景のコントラストがほとんどない。
- 最大値は約 4000 (12bit の上限付近) にそろっている。ヘッダの TR は 0。
- FreeSurfer は「背景が暗く、白質がはっきりしたピークを持つ」ことを前提にしているので、次のステップが失敗する:
  - Talairach 位置合わせ (`talairach_avi` / `talairach_afd`)
  - 強度の正規化 (`mri_normalize`) と、正規化された白質 (値 110) を使う頭蓋除去 (`mri_watershed`)
- 前処理を通過しても、トポロジー修正で巨大な欠損 (数万頂点) が残って止まることがある。

## 3. 失敗の種類ごとの説明

recon-all の実行順に並べている。

| | ステップ | エラー | 6.0 | 7.4.1 | 8.2.0 |
|---|---|---|---:|---:|---:|
| A | `talairach_avi` | mpr2mni305 failed | 2 | 2 | – |
| B | `talairach_afd` | Talairach failed! | 4 | 7 | – |
| C | `mri_watershed` | COG calculation (白質が 110 に正規化されていない) | 5 | 4 | – |
| D | `mri_normalize` | HISTOalloc(-2147483648) | – | – | 12 |
| E | `mris_fix_topology` | 停止・時間切れ | 2 | 1 | 5 |
| F | `mris_fix_topology` | MRIthickenThinWMStrands: invalid x,y,z! | 1 | – | – |
| G | `seg2cc` | MRIlinearTransform: xform is singular | – | – | 1 |
| H | `label-cortex` | found no voxels matching id 1 | – | – | 1 |

### A. `talairach_avi`: "mpr2mni305 failed"
MNI305 アトラスへのアフィン位置合わせそのものが失敗した。
該当者は `sub-675789932781` と `sub-873597053285` で、6.0 と 7.4.1 で同じ被験者。

### B. `talairach_afd`: "Talairach failed!"
位置合わせはできたが、変換行列が正常範囲から外れていると判定された (品質チェックで不合格)。
- 例: `sub-715300585465` (6.0) は p=0.0003、pval=0.0000 で閾値 0.005 を下回った。
- 7.4.1 の方が該当者が多い。`sub-122383009817` と `sub-954854557667` は、6.0 では完了している。

### C. `mri_watershed` (頭蓋除去)
`check_status.sh` では原因が「不明」と出るが、`recon-all.log` には次のように出ている:

```
Problem in the COG calculation:
T1.mgz may not contain properly normalized white-matter.
Confirm that T1.mgz has enough white-matter voxels of value 110.
```

7.4.1 の `sub-178107515306` では "number of peaks must be > 1 for spline" と出ている。
どちらも、強度の正規化 (`T1.mgz`) で白質が 110 にそろわず、脳の重心が計算できないことを示している。

### D. `mri_normalize`: "HISTOalloc(-2147483648): could not allocate histogram"
8.2.0 だけで起きる。
- "white matter peak found at 110" の直後に "Cannot allocate memory" が出て、HISTOalloc(-2147483648) で落ちる。
- ヒストグラムのビン数が int の最小値 (オーバーフロー) になっているので、メモリ不足ではない。メモリを増やして再実行しても同じ結果になった。
- site 38 の異常な強度分布が原因と考えられる。
- 8.2.0 は Talairach を SynthMorph で行うので A・B は起きないが、その次の正規化で止まる。

### E. `mris_fix_topology` での停止・時間切れ
皮質表面のトポロジー修正で巨大な欠損があり、処理が終わらない。

| バージョン | 被験者 | 欠損の数 | 最大の欠損 |
|---|---|---:|---|
| 8.2.0 | `sub-352362867687` | 13 | DEFECT 0, vertices=61084 |
| 8.2.0 | `sub-547107069770` | 8 | DEFECT 0, vertices=37911 |
| 6.0 | `sub-547107069770` | 92 | DEFECT 0, vertices=31190 |
| 6.0 | `sub-521804912208` (site 64) | 154 | DEFECT 35, vertices=13196 |

- `sub-547107069770` は 3バージョンすべてで Fix Topology から先に進まない。
- 8.2.0 の 5 人と 7.4.1 の 1 人は、時間切れ機能 (`JOB_TIMEOUT`) を入れる前の実行だったので、手動で停止した。

### F. `mris_fix_topology`: "MRIthickenThinWMStrands: invalid x,y,z!"
`sub-385846642581` (6.0)。白質のセグメンテーションが異常なために起きた座標エラー。

### G. `seg2cc`: "MRIlinearTransform: xform is singular"
`sub-213442744017` (8.2.0, site 38)。脳梁のセグメンテーションで、変換行列が特異 (逆行列がない) になった。6.0 と 7.4.1 では完了している。

### H. `label-cortex`: "found no voxels matching id 1"
`sub-277976850330` (8.2.0, site 36, 78 歳)。皮質ラベルを作るときに、対象ラベルの画素が見つからなかった。
6.0 と 7.4.1 では完了している。site 38 以外で 8.2.0 だけが失敗した唯一の被験者。

## 4. 被験者ごとの比較

3バージョンすべてでは完了しなかった 22 人の一覧。

- 状態の意味: done = 完了、failed = 失敗、timeout = 24h 時間切れ、stopped = Fix Topology で止まり手動停止
- 括弧内は完了した場合の所要時間、それ以外は失敗したステップ / 原因

| 被験者 | site | 性別 / 年齢 | 6.0 | 7.4.1 | 8.2.0 |
|---|---|---|---|---|---|
| sub-122383009817 | 38 | M / 22.5 | done (9.31h) | failed: talairach_afd | done (4.66h) |
| sub-171261643379 | 38 | M / 27.5 | failed: mri_watershed (COG) | failed: mri_watershed (COG) | failed: mri_normalize (HISTOalloc) |
| sub-178107515306 | 38 | F / 27.5 | failed: mri_watershed (COG) | failed: mri_watershed (peaks) | failed: mri_normalize (HISTOalloc) |
| sub-205481948499 | 38 | M / 37.5 | failed: mri_watershed (COG) | done (7.07h) | failed: mri_normalize (HISTOalloc) |
| sub-213442744017 | 38 | M / 22.5 | done (12.51h) | done (6.72h) | failed: seg2cc (xform is singular) |
| sub-221041358919 | 38 | M / 27.5 | failed: mri_watershed (COG) | failed: mri_watershed (COG) | failed: mri_normalize (HISTOalloc) |
| sub-277976850330 | 36 | F / 78.4 | done (8.30h) | done (6.24h) | failed: label-cortex |
| sub-287272151464 | 38 | F / 22.5 | failed: mri_watershed (COG) | failed: talairach_afd | failed: mri_normalize (HISTOalloc) |
| sub-352362867687 | 38 | F / 57.5 | failed: talairach_afd | failed: talairach_afd | stopped: Fix Topology lh (61084 vertices) |
| sub-385846642581 | 38 | F / 42.5 | failed: mris_fix_topology (invalid x,y,z) | failed: talairach_afd | failed: mri_normalize (HISTOalloc) |
| sub-521804912208 | 64 | M / 14.9 | timeout: Fix Topology lh | done (7.18h) | done (3.57h) |
| sub-547107069770 | 38 | F / 67.5 | timeout: Fix Topology lh | stopped: Fix Topology lh (30h) | stopped: Fix Topology rh |
| sub-557061769391 | 38 | F / 27.5 | failed: talairach_afd | failed: talairach_afd | done (4.32h) |
| sub-607182654630 | 38 | M / 22.5 | done (8.80h) | done (6.18h) | failed: mri_normalize (HISTOalloc) |
| sub-622282127153 | 38 | M / 22.5 | done (10.31h) | done (8.95h) | failed: mri_normalize (HISTOalloc) |
| sub-675789932781 | 38 | M / 57.5 | failed: talairach_avi | failed: talairach_avi | stopped: Fix Topology lh |
| sub-715300585465 | 38 | M / 27.5 | failed: talairach_afd | failed: talairach_afd | failed: mri_normalize (HISTOalloc) |
| sub-858420327833 | 38 | M / 27.5 | done (9.88h) | done (7.84h) | stopped: Fix Topology lh |
| sub-873597053285 | 38 | M / 27.5 | failed: talairach_avi | failed: talairach_avi | failed: mri_normalize (HISTOalloc) |
| sub-889268221373 | 38 | F / 27.5 | failed: talairach_afd | failed: mri_watershed (COG) | failed: mri_normalize (HISTOalloc) |
| sub-909626055335 | 38 | M / 22.5 | done (10.32h) | done (9.85h) | failed: mri_normalize (HISTOalloc) |
| sub-954854557667 | 38 | M / 22.5 | done (9.05h) | failed: talairach_afd | stopped: Fix Topology lh |

## 5. バージョンごとの傾向

- **6.0**
  - site 38 の失敗は前処理 (Talairach 6 人、mri_watershed 5 人) が中心。
  - site 64 の 1 人が Fix Topology で時間切れになったのは 6.0 だけ。
- **7.4.1**
  - 6.0 とほぼ同じ傾向だが、talairach_afd で落ちる人が多い (7 人)。
- **8.2.0**
  - SynthMorph を使うので Talairach では落ちないが、site 38 の 12 人が mri_normalize の HISTOalloc で落ちる。
  - 前処理を通過した site 38 の 5 人は、Fix Topology で止まった。
  - site 38 以外でも 1 人 (`sub-277976850330`) が label-cortex で落ちた。

## 6. 今後の対応の候補 (未実施)

- site 38 を解析対象から外す。3バージョンを比べるときは、すべて完了した 735 人を使う。
- site 38 の画像に前処理をしてから再実行する。
  例: 背景のマスク処理、N4 バイアス補正、強度の再スケール、`-noskullstrip` などのオプションを試す。
- site 38 以外の 2 人 (`sub-277976850330`、`sub-521804912208`) はバージョン固有の問題なので、失敗したバージョンだけ再実行するか、そのまま除外する。
