# Slurm + Singularity 版 (`scripts/singularity/`)

Slurm クラスタで、OpenBHB train などを **複数ノードに分けて** `recon-all` で処理する。既定パスはこのクラスタ (`mprg-cluster-master`) に合わせてある。
Docker 版 ([`scripts/docker/`](../docker/README.md)) とはスクリプトを共有しない。開発・動作確認は FreeSurfer 7.4.1 で行う。

| ファイル | 役割 |
|---|---|
| `submit_openbhb_train_<ver>.sh` | 入口。バージョンごとの既定値 (ノード数、CPU 数、`MEM_PER_JOB` など) を設定して `submit_recon.sh` を呼ぶ |
| `submit_recon.sh` | マスターで実行。被験者を列挙し、完了済みを除き、`NUM_NODES` 個のリストに分けて `sbatch --array` で投入する |
| `recon_array_job.sh` | 配列タスク1つ (1ノード) の処理。担当リストを `singularity exec ... parallel` で処理する |
| `recon_worker.sh` | コンテナ内で被験者1人分の recon-all を実行する (GNU Parallel から呼ばれる) |
| `check_status.sh` | `SUBJECTS_DIR` の各被験者の状態を一覧にする (Slurm のジョブと照らして実行中/中断を判定) |

コマンドはすべてプロジェクトのルートディレクトリから実行する。
FreeSurfer のライセンス `license.txt` を `fs_license/license.txt` に置いておく。

## 実行方法

被験者を **使用するノード数 (`NUM_NODES`) 個のリストに分け**、`sbatch --array` の各タスク (1ノード) が担当リストを GNU Parallel で処理する。

```bash
# 1. イメージをビルド (マスターノードで。既定で --fakeroot を付ける)
containers/singularity/build.sh              # 6.0 / 7.4.1 / 8.2.0 → containers/singularity/freesurfer_<ver>_parallel.sif
containers/singularity/build.sh 7.4.1        # 1つだけ (開発・テストは 7.4.1 を使う)

# 2. 分割結果と sbatch コマンドの確認 (投入しない)
DRY_RUN=1 scripts/singularity/submit_openbhb_train_7.4.1.sh

# 3. 先頭2人を1ノードでテスト
LIMIT=2 NUM_NODES=1 scripts/singularity/submit_openbhb_train_7.4.1.sh

# 4. 本番 (既定: 8ノード × 32 CPU)。マスターで bash として実行する (sbatch しない)
scripts/singularity/submit_openbhb_train_7.4.1.sh
NUM_NODES=6 CPUS_PER_NODE=48 EXCLUDE_NODES=node01 scripts/singularity/submit_openbhb_train_7.4.1.sh

# 5. 進捗
squeue -u $USER
scripts/singularity/check_status.sh /shared_datasets/BrainMRIDatasets/fs_output/openBHB/train/freesurfer_7.4.1
```

- 入力は `/dataset02/mri_data/openBHB` (各計算ノードのローカルディスク)、出力は
  `/shared_datasets/BrainMRIDatasets/fs_output/openBHB/<split>/freesurfer_<ver>/` (共有ストレージ)。
- 被験者はラウンドロビンで分ける (同じサイトの被験者が1ノードに偏らないように)。
- 投入時に、完了済みの被験者 (と、`RETRY_TIMEOUT=1` でなければ時間切れの被験者) はリストから除く。
  途中で止まった・失敗した被験者は、同じスクリプトをもう一度実行すれば残りだけが投入される。
- 同名のジョブ (`fs<ver>_openBHB_train`) が投入済み・実行中なら、二重処理を防ぐため投入を中止する (`FORCE_SUBMIT=1` で無視)。
- 配列タスクが制限時間 (`TIME_LIMIT`, 既定 7日) で止められた場合、処理中だった被験者は次回の投入で最初からやり直しになる。
  投入時に表示される「約 N 巡 / 約 X〜Y 時間」の目安が `TIME_LIMIT` を超えないように `NUM_NODES` と `CPUS_PER_NODE` を決める。

投入ごとのログ (`<SUBJECTS_DIR>/_logs/run_<日時>/`):

```
run_info.txt          # 投入時のパラメータ、被験者数、sbatch コマンド、ジョブ ID
lists/node_000.txt    # 配列タスク 0 が担当する被験者 ID (1行1人)
slurm/slurm_<jobid>_<task>.out   # 各タスクの出力 (ノード名、空きメモリ、終了コードの集計)
joblog/node_000.txt   # GNU Parallel のジョブログ
results/node_000/     # 被験者ごとの stdout / stderr
```

Slurm 用のパラメータ (環境変数で上書き。`submit_openbhb_train_<ver>.sh` の冒頭の既定値を編集してもよい):

| 変数 | 既定値 | 説明 |
|---|---|---|
| `NUM_NODES` | `8` | 被験者リストの分割数 = 配列タスク数 (1タスク = 1ノード分) |
| `CPUS_PER_NODE` | `32` | 1タスクの CPU 数 (`--cpus-per-task`)。同時処理数 `JOBS` = `CPUS_PER_NODE / THREADS_PER_JOB` |
| `MEM_PER_JOB` | 6.0: `6` / 7.4.1: `4` / 8.2.0: `12` | 1被験者のメモリ (GB)。`--mem` = `JOBS × MEM_PER_JOB` |
| `PARTITION` | `a6000_ada` | パーティション |
| `TIME_LIMIT` | `7-00:00:00` | 1タスクの制限時間 |
| `MAX_CONCURRENT` | (なし) | 同時に動かすタスク数の上限 (`--array=...%N`) |
| `EXCLUDE_NODES` | (なし) | 使わないノード (`--exclude`。例: `node01,node02`) |
| `EXCLUSIVE` | `0` | 1 ならノードを専有 (`--exclusive`) |
| `EXTRA_SBATCH_OPTS` | (なし) | その他の sbatch オプション |
| `START_DELAY` | `30` | ノード内でジョブを開始する間隔 (秒, `parallel --delay`)。序盤の重いステップが一斉に重ならないように |
| `MEMFREE` | `0` | >0 なら空きメモリが `MEMFREE` GB 未満のとき次の被験者を始めない (`parallel --memfree`) |
| `FORCE_SUBMIT` | `0` | 1 なら同名ジョブが動いていても投入する |
| `DATA_ROOT` | `/dataset02/mri_data/openBHB` | OpenBHB のルート (計算ノードから同じパスで見えること) |
| `OUTPUT_ROOT` | `/shared_datasets/BrainMRIDatasets/fs_output` | 出力のルート |
| `SIF_IMAGE` | `containers/singularity/freesurfer_<ver>_parallel.sif` | Singularity イメージ |

| `THREADS_PER_JOB` | `1` | `recon-all -openmp` の値 |
| `RECON_FLAGS` | `-all` | `recon-all` に渡す追加オプション (例: `"-all -qcache"`) |
| `JOB_TIMEOUT` | `24h` | 1被験者の制限時間 (`90m`, `36h`, `2d` など。`0` で無制限)。過ぎたら止めて `scripts/recon-all.timeout` を作る |
| `RETRY_TIMEOUT` | `0` | 1 なら、前回時間切れになった被験者もやり直す (既定ではリストから除く) |
| `LIMIT` | `0` | 0 なら全員。N > 0 なら先頭 N 人のみ (テスト用) |
| `DRY_RUN` | `0` | 1 なら投入せず、分割結果と sbatch コマンドを表示するだけ |
| `FS_LICENSE_FILE` | `fs_license/license.txt` | ライセンスファイル |

全パラメータは `submit_recon.sh` の冒頭にある。

このクラスタでの注意:

- Slurm はメモリを確保も制限もしない (`CR_CPU`、cgroup の `memory.max` が無制限)。`--mem` を付けても、同じノードの他のジョブとメモリを取り合う。
  `JOBS × MEM_PER_JOB` に余裕を持たせ、8.2.0 など重いものは `EXCLUSIVE=1` や `MEMFREE` も検討する。
- Slurm の CPU 数は論理コア (ハイパースレッド込み)。
- 出力先 (`/shared_datasets`) に書き込めないノードに割り当てられると、ログも残らず即 FAILED (`sacct` の ExitCode `0:53`) になる
  (2026-11-24 に node02 で発生、修正済み)。その場合は `EXCLUDE_NODES` でそのノードを除外して再投入する。
- `srun` は interactive パーティションでしか使えないので、ジョブ内では `singularity exec` を直接呼んでいる。


## 進捗と失敗の確認 (`check_status.sh`)

```bash
O=/shared_datasets/BrainMRIDatasets/fs_output/openBHB/train/freesurfer_7.4.1
scripts/singularity/check_status.sh $O                 # 集計 + 完了以外の被験者の一覧
scripts/singularity/check_status.sh -a $O              # 完了した被験者も含めて全員
scripts/singularity/check_status.sh -r /dataset02/mri_data/openBHB/train/rawdata $O   # 未着手も数える
scripts/singularity/check_status.sh -o ~/status_train741 $O   # 状態ごとの被験者リストを保存
```

| 状態 | 判定 |
|---|---|
| `done` | `recon-all.done` に `END_TIME` があり、それより新しい `recon-all.error` がない |
| `timeout` | `recon-all.timeout` がある (`JOB_TIMEOUT` を過ぎたため止めた) |
| `failed` | `recon-all.error` がある (失敗したステップと原因を表示。`Killed` ならメモリ不足の可能性大) |
| `running` | `IsRunning.*` があり、その `HOST` (ノード名) で自分の Slurm ジョブが動いている |
| `interrupted` | `IsRunning.*` があるが、そのノードで自分のジョブが動いていない (時間切れ・`scancel` 等で中断) |
| `running?` | `IsRunning.*` があるが判断できない (`HOST` が空など) |
| `incomplete` | 上のどれでもない |
| `not_started` | rawdata にあるが `SUBJECTS_DIR` にない (`-r` 指定時のみ) |

- FreeSurfer 8 は失敗時にも `recon-all.done` (中身は `1` のみ) を作るので、`recon-all.done` の有無だけでは完了を判定しない。
- 失敗・中断した被験者は、`submit_openbhb_train_<ver>.sh` を再実行すれば (前回のログを `scripts/prev_<日時>/` に退避して) 最初からやり直される。
