# FreeSurfer × GNU Parallel

OpenBHB をはじめとする T1w MRI を FreeSurfer の `recon-all` で一括処理するスクリプト群です。
Docker コンテナ内の GNU Parallel で、被験者単位に並列実行します。

## ディレクトリ構成

```
.
├── containers/docker/        # FreeSurfer + GNU Parallel の Dockerfile と build.sh (6.0 / 7.4.1 / 8.2.0)
├── containers/singularity/   # 同じ内容の Singularity 定義ファイル (.def) と build.sh
├── fs_license/license.txt    # FreeSurfer ライセンス (git 管理しないこと)
├── reports/                  # 解析結果のレポート (失敗のまとめ、公開データとの比較)。reports/README.md を参照
└── scripts/
    ├── recon_worker.sh       # 被験者1人分の recon-all (Docker/Singularity 共通)
    ├── check_status.sh       # SUBJECTS_DIR の各被験者の状態 (完了/失敗/中断など) を一覧にする
    ├── compare_openbhb_fs.py # OpenBHB 公開の FreeSurfer ROI 特徴量と自分の結果を比較する
    ├── docker/               # Docker 用 process_openbhb_<split>_<ver>.sh (6本)
    └── singularity/          # Singularity + Slurm 用 process_openbhb_<split>_<ver>.sh (6本)
```

## 事前準備

1. イメージをビルドする (`freesurfer:6.0-parallel`, `freesurfer:7.4.1-parallel`, `freesurfer:8.2.0-parallel` ができる)。

   ```bash
   cd containers/docker && ./build.sh
   # 1つだけ作る場合
   docker build -f Dockerfile_fs_6.0 -t freesurfer:6.0-parallel .
   ```

   FreeSurfer 6.0 のイメージは他と次の点が違う (スクリプト側で対応済み)。

   | | 6.0 | 7.4.1 / 8.2.0 |
   |---|---|---|
   | ベース OS | Ubuntu 14.04 (`apt`) | RHEL 系 (`dnf`) |
   | `FREESURFER_HOME` | `/opt/freesurfer` | `/usr/local/freesurfer` |
   | GNU Parallel | 20161222 (trusty-backports) | EPEL の最新版 |
   | ライセンス | 環境変数 `FS_LICENSE` を見ない。イメージ内の `/opt/freesurfer/license.txt` → `/fs_license/license.txt` のシンボリックリンク経由で読む | `FS_LICENSE` で指定 |

2. FreeSurfer のライセンスファイル `license.txt` を `fs_license/license.txt` に置く。
   別の場所に置く場合は `FS_LICENSE_FILE` で指定する (後述)。

## 実行方法

```bash
# 1. 実行内容の確認だけ (recon-all は走らない)
DRY_RUN=1 scripts/docker/process_openbhb_val_8.2.0.sh

# 2. 1人だけ本番実行して動作確認
LIMIT=1 scripts/docker/process_openbhb_val_8.2.0.sh

# 3. 全員を処理
scripts/docker/process_openbhb_val_8.2.0.sh

# 長時間かかるので、ログアウトしても続けたい場合 (ログは logs_docker/ に出す。git 管理外なので初回は mkdir する)
mkdir -p logs_docker
nohup scripts/docker/process_openbhb_train_7.4.1.sh > logs_docker/train_7.4.1.log 2>&1 &
```

- スクリプト名は `process_openbhb_<split>_<FreeSurferバージョン>.sh` (split は `train` / `val`)。
- 被験者数は train 3227 人、val 757 人。1人あたり数時間かかる。
- 完了済みの被験者 (`scripts/recon-all.done` に `END_TIME` の行がある) はスキップされる。
- 失敗・中断した被験者は、前回のログを `scripts/prev_<日時>/` に退避してから `-all` でやり直す。
  途中のステップからの再開ではなく、最初のステップからやり直しになる。
  中断しても同じコマンドを再実行すればよい。
- 1人の処理が `JOB_TIMEOUT` (既定 24時間) を過ぎても終わらなければ、その被験者の処理を止めて次に進む (後述)。

### 実行スクリプトの例

```bash
# OpenBHB val 8.2.0
JOBS=60 MEM_PER_JOB=8 nohup scripts/docker/process_openbhb_val_8.2.0.sh > logs_docker/val_8.2.0.log 2>&1 &
```

## Singularity / Slurm で実行する

Docker 用 (`scripts/docker/`) と Singularity + Slurm 用 (`scripts/singularity/`) は別々のスクリプト。

```bash
# 1. イメージをビルド (クラスタ側でビルドできなければ手元でビルドして .sif を転送)
cd containers/singularity && ./build.sh        # root なしなら SINGULARITY_BUILD_OPTS="--fakeroot" ./build.sh

# 2. 必要ならパスを環境変数で合わせる (DATA_ROOT, OUTPUT_ROOT, SIF_IMAGE など)

# 3. Slurm に投入 (プロジェクトディレクトリで実行する)
sbatch scripts/singularity/process_openbhb_val_8.2.0.sh                          # 1ノード
sbatch --cpus-per-task=16 --mem=96G scripts/singularity/process_openbhb_val_8.2.0.sh   # 資源を変更
sbatch --array=0-9 scripts/singularity/process_openbhb_train_8.2.0.sh            # 10ノードに被験者を自動分割
sbatch --export=ALL,LIMIT=1 scripts/singularity/process_openbhb_val_8.2.0.sh   # 1人だけのテスト

# Slurm なしで内容だけ確認 (dry-run)
DRY_RUN=1 bash scripts/singularity/process_openbhb_val_8.2.0.sh
```

- スクリプト先頭の `#SBATCH` 行 (CPU 8、メモリ 48GB、72時間など) が既定の資源。クラスタに合わせて編集するか、`sbatch` のオプションで上書きする。
  `bash` で直接実行したときは無視される。
- Slurm 内では `JOBS` は割り当てコア数 ÷ `THREADS_PER_JOB` から自動で決まる。メモリは `--mem` に `JOBS × MEM_PER_JOB` GB 以上を指定する。
- 配列ジョブでは `SLURM_ARRAY_TASK_ID` に応じて被験者リストが分割される。手動で分けるときは `SHARD_COUNT` と `SHARD_INDEX` を指定する。
- `sbatch` はスクリプトを別の場所にコピーして実行するので、プロジェクトのルートディレクトリから投入するか、`PROJECT_DIR=/path/to/FreeSurferMultiProcess` を指定する。
- `fs_license/license.txt` と `.sif` の既定パスは `PROJECT_DIR` 基準 (`containers/singularity/freesurfer_<ver>_parallel.sif`)。

## パラメータ

環境変数で上書きできる。スクリプト冒頭の既定値を直接編集してもよい。

```bash
JOBS=4 MEM_PER_JOB=8 scripts/docker/process_openbhb_train_8.2.0.sh
```

| 変数 | 既定値 | 説明 |
|---|---|---|
| `JOBS` | `8` | 同時に処理する被験者数 |
| `MEM_PER_JOB` | `6` | 1ジョブあたりのメモリ (GB)。コンテナのメモリ上限は `JOBS × MEM_PER_JOB` GB |
| `THREADS_PER_JOB` | `1` | `recon-all -openmp` の値。CPU 上限は `JOBS × THREADS_PER_JOB` コア |
| `RECON_FLAGS` | `-all` | `recon-all` に渡す追加オプション (例: `"-all -qcache"`) |
| `JOB_TIMEOUT` | `24h` | 1人あたりの制限時間。`timeout` コマンドの書式 (`90m`, `36h`, `2d` など)。`0` で無制限 |
| `RETRY_TIMEOUT` | `0` | 1 なら、前回時間切れになった被験者もやり直す (既定ではスキップ) |
| `LIMIT` | `0` | 0 なら全員。N > 0 なら先頭 N 人のみ (テスト用) |
| `DRY_RUN` | `0` | 1 なら実行内容を表示するだけ |
| `FS_LICENSE_FILE` | `./fs_license/license.txt` | ライセンスファイルのホスト側パス |
| `DATA_ROOT` | `/raid/hirakawa/datasets/openBHB` | OpenBHB のルート |
| `OUTPUT_ROOT` | `/raid/hirakawa/fs_output` | 出力のルート |
| `SIF_IMAGE` | `containers/singularity/freesurfer_<ver>_parallel.sif` | Singularity イメージ |
| `SHARD_COUNT` / `SHARD_INDEX` | `1` / `0` | 被験者リストの分割数と担当番号 (Slurm 配列では自動) |
| `PROJECT_DIR` | スクリプトの場所 | `fs_license/license.txt` や `.sif` の基準ディレクトリ |
| `DOCKER_IMAGE` | `freesurfer:<ver>-parallel` | 使用する Docker イメージ |

別のサーバーで使うときは、コア数とメモリに合わせて `JOBS` と `MEM_PER_JOB` を調整する。
CPU は 1ジョブあたり 1 コア (`THREADS_PER_JOB=1`) が基本。メモリの目安は FreeSurfer のバージョンで異なる。

| バージョン | `MEM_PER_JOB` の目安 | 根拠 |
|---|---|---|
| 8.2.0 | **12〜16GB** | 序盤の `mri_synthmorph` (`fs-synthmorph-reg`) が 1プロセス約 9〜10GB を使う (実測、40並列時)。`mri_synthseg` も数 GB 以上使う |
| 7.4.1 | 4〜8GB | 1プロセスのピークは約 2.1GB、100並列でコンテナ全体約 150GB (実測)。SynthMorph / SynthSeg を使わない |
| 6.0 | 4〜8GB (未実測) | 7.4.1 と同程度の見込み |

- `--memory` (`JOBS × MEM_PER_JOB`) はコンテナ全体の上限で、ジョブごとの上限ではない。
  全ジョブが同時に始まると序盤の重いステップが重なるので、ピークはおおよそ `JOBS × 1ジョブのピーク` になる。
  これが上限を超えると、どれかのプロセスが `Killed` で強制終了され、その被験者は失敗する。
- 実例: 8.2.0 を `JOBS=60 MEM_PER_JOB=8` (上限 480GB) で実行したら、開始直後に 46 人が
  `fs-synthmorph-reg` / `mri_synthseg` の `Killed` で失敗した。`JOBS=40 MEM_PER_JOB=16` (上限 640GB) では、
  序盤のピークは約 400GB で収まった。
- 新しい環境では `LIMIT` を小さくして試し、`docker stats` でピークを確認してから `JOBS` を決めるとよい。
- スワップがないホストでは、`JOBS × MEM_PER_JOB` を物理メモリより十分小さくしておく。

## 時間切れ (`JOB_TIMEOUT`)

`mris_fix_topology` などが終わらなくなる被験者がいる (val の site 38 で、7.4.1 と 8.2.0 の両方で数日間進まない例があった)。
そのまま放置すると並列の枠を1つ占有し続けるので、`recon_worker.sh` は `recon-all` を `timeout` コマンド経由で起動している。

- 開始から `JOB_TIMEOUT` を過ぎると、`recon-all` とその子プロセスに SIGTERM を送る。10分以内に終わらなければ SIGKILL。
- 止めた被験者には `sub-XXX/scripts/recon-all.timeout` を作る (止めた時点のステップ、開始・停止時刻)。
  `IsRunning.*` は消す。`joblog.txt` の `Exitval` は `124`。
- 再実行したとき、時間切れの被験者は既定でスキップする (`Exitval` は `3`)。同じ箇所でまた止まる可能性が高いため。
  やり直す場合は `RETRY_TIMEOUT=1` を付ける (前回のログと `recon-all.timeout` を `prev_<日時>/` に退避してやり直す)。
- 正常な1人あたりの処理時間は、8.2.0 で最大約 6 時間、7.4.1 で最大約 10 時間 (100並列時)。
  1コアの性能が低い環境や、並列数が多く遅くなる環境では `JOB_TIMEOUT` を延ばす。

```bash
# 制限時間を 36 時間にする
JOB_TIMEOUT=36h JOBS=60 nohup scripts/docker/process_openbhb_val_6.0.sh > logs_docker/val_6.0.log 2>&1 &

# 時間切れになった被験者だけ、制限時間を延ばしてやり直す (完了済みはスキップされる)
RETRY_TIMEOUT=1 JOB_TIMEOUT=72h scripts/docker/process_openbhb_val_6.0.sh
```

## 入出力

入力: `${DATA_ROOT}/<split>/rawdata/sub-*/ses-1/sub-*_T1w.nii[.gz]`

出力 (`SUBJECTS_DIR`): `${OUTPUT_ROOT}/openBHB/<split>/freesurfer_<ver>/`

```
/raid/hirakawa/fs_output/openBHB/val/freesurfer_8.2.0/
├── sub-*/            # 被験者ごとの recon-all 結果
└── _logs/
    ├── joblog.txt    # GNU Parallel のジョブログ (終了コード・所要時間)
    └── results/      # 被験者ごとの stdout / stderr
                      # (分割実行時は joblog_shard<N>.txt と results_shard<N>/)
```

## 進捗と失敗の確認 (`check_status.sh`)

`scripts/check_status.sh` に `SUBJECTS_DIR` を渡すと、各被験者の状態を集計して一覧にする。
実行中でも使える (`SUBJECTS_DIR` の中は読むだけで変更しない)。

```bash
O=/raid/hirakawa/fs_output/openBHB/val/freesurfer_8.2.0

scripts/check_status.sh $O                  # 集計 + 完了以外の被験者の一覧
scripts/check_status.sh -a $O               # 完了した被験者も含めて全員を表示
scripts/check_status.sh -r /raid/hirakawa/datasets/openBHB/val/rawdata $O   # 未着手の被験者も数える
scripts/check_status.sh -o ~/status_val820 $O   # 状態ごとの被験者リストを保存
```

| オプション | 説明 |
|---|---|
| `-a` | 完了 (`done`) の被験者も一覧に表示する (既定では完了以外のみ) |
| `-r <RAW_DIR>` | rawdata と比べて、まだ `SUBJECTS_DIR` にない被験者を `not_started` として数える |
| `-o <DIR>` | `<DIR>/status.tsv` (全員の状態) と、状態ごとの被験者 ID リスト (`done.txt`, `failed.txt` など) を保存する |

状態の判定基準:

| 状態 | 判定 | 一覧の DETAIL 列 |
|---|---|---|
| `done` | `recon-all.done` に `END_TIME` があり、それより新しい `recon-all.error` がない | 所要時間 |
| `timeout` | `recon-all.timeout` がある (`JOB_TIMEOUT` を過ぎたため止めた) | 制限時間。STEP 列は止めた時点のステップ |
| `failed` | `recon-all.error` がある | 失敗したステップと、`recon-all.log` から拾ったエラー行 (`Killed` ならメモリ不足の可能性大) |
| `running` | `IsRunning.*` があり、記録されたコンテナが実行中 | - |
| `interrupted` | `IsRunning.*` があるが、そのコンテナはもう動いていない (`docker stop` 等で中断) | - |
| `running?` | `IsRunning.*` があるが、実行中か判断できない (Singularity / 別ホスト) | ホスト名 |
| `incomplete` | 上のどれでもない (ディレクトリだけ作られて止まった等) | - |
| `not_started` | rawdata にあるが `SUBJECTS_DIR` にない (`-r` 指定時のみ) | - |

出力例:

```
SUBJECTS_DIR: /raid/hirakawa/fs_output/openBHB/val/freesurfer_8.2.0
  done           692
  failed          60
  interrupted      5
  total          757

失敗の内訳 (件数 / ステップ / 原因):
       40 fs-synthmorph-reg  Killed
       12 mri_normalize  error: HISTOalloc(-2147483648): could not allocate histogram
        6 mri_synthseg  Killed
       ...

SUBJECT              STATUS       STEP                         DETAIL
sub-101428024622     failed       fs-synthmorph-reg            Killed (メモリ不足の可能性大)
...
sub-352362867687     interrupted  Fix Topology lh Thu Nov  5 ...  container 531a76f7ad5e は停止済み
```

注意:

- FreeSurfer 8 は失敗時にも `recon-all.done` (中身は `1` のみ) を作るので、
  `recon-all.done` の有無だけで完了を数えると失敗した被験者も含まれてしまう。
- `running` のまま `recon-all-status.log` の最終行 (STEP 列) が何日も変わらない被験者は、
  `mris_fix_topology` などで止まっている可能性がある。
- 失敗・中断した被験者は、スクリプトを再実行すれば (前回のログを退避して) やり直される。
  `Killed` で失敗した場合は `JOBS` を減らし `MEM_PER_JOB` を増やして再実行する。

その他の確認方法:

```bash
# GNU Parallel のジョブログで失敗したジョブ (Exitval が 0 以外)
awk -F'\t' 'FNR>1 && $7!=0 {print $9}' $O/_logs/joblog*.txt

# 1人の進み具合
tail -f $O/sub-XXXX/scripts/recon-all-status.log

# コンテナの状態
docker ps
```

## 補足

- コンテナはホストと同じ UID/GID で動くので、出力ファイルの所有者は実行ユーザーになる。
- `joblog.txt` と `results/` は再実行のたびに上書き・追記される。残したい場合は退避しておく。
