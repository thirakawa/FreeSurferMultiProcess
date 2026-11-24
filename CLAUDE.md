# FreeSurfer with GNU Parallel for Multi-Processing MRI Brain Datasets

FreeSurferで大量のMRIデータを処理するために、GNU Parallelを活用したスクリプトを作成し、処理を実行するためのプロジェクトです。

主に，Dockerを使用したスクリプトとSlurm + Singularityを使用したスクリプトの2種類を開発します。

**2種類のスクリプトは互いに独立させ、ファイルを共有しない** (依存関係を単純に保つため)。
`recon_worker.sh` や `check_status.sh` のように両方で必要なものも、`scripts/docker/` と `scripts/singularity/` にそれぞれ置き、別々に修正する。
片方を直したときに、もう片方にも同じ修正が必要かは個別に判断する (Docker 版は別サーバー用で、原則として変更しない)。
共有してよいのは、実行に関わらない `fs_license/license.txt` と解析用の `scripts/compare_openbhb_fs.py` だけ。

## Docker版の情報

### FreeSurferとGNU Parallelの環境

`./containers/docker` ディレクトリに、FreeSurferのイメージをベースにGNU ParallelをインストールしたイメージをビルドするためのDockerfileを定義している。

FreeSurferのバージョンの観点から、6.0、7.4.1、8.2.0の3つを作成している。

### スクリプト (`scripts/docker/`)

`process_openbhb_<split>_<ver>.sh` (実行スクリプト)、`recon_worker.sh` (被験者1人分)、`check_status.sh` (状態の一覧)。使い方は `scripts/docker/README.md`。

### 作成して欲しいスクリプト

FreeSurferの `recon-all` とGNU Parallelを用いて、リソースの許す限り並列で同時に全てのMRIデータを処理するスクリプトを作成して欲しい。
train / valなどの適当な括りごとにスクリプトを作成して欲しい。

現在使用している端末以外のサーバーでも使用できるように、並列数や１ジョブあたりのメモリ量などのパラメータはスクリプトの変数などとして適宜修正して実行できるようにして欲しい。

### 処理したデータの保存場所

`/raid/hirakawa/fs_output` ディレクトリ以下に適宜適切なディレクトリパスを設定して保存するようにして欲しい（データセットやtrain/val、FreeSurferのバージョンなど）。

```bash
export SUBJECTS_DIR=/raid/hirakawa/fs_output/...
```

## Slurm + Singularity版の情報

Docker 版とは別のサーバー (Slurm クラスタ `mprg-cluster-master`) で実行するので、既定パスは Docker 版と異なってよい。Docker 版のスクリプトは変更しない。

### 対象と方針

- 主な対象は OpenBHB の **train (3227人)**。1ノードでは時間がかかりすぎる (パーティションの上限は 7日) ので、複数ノードに分けて処理する。
- ディレクトリを丸ごと渡すのではなく、**使用するノード数に応じて被験者リストを分割し、各ノード (Slurm 配列タスク1つ) が担当リストを GNU Parallel で並列処理する**。
- 再実行したときは、完了済みの被験者を除いた残りだけを分割して投入する。

### 使用する FreeSurfer のバージョン

- イメージは 6.0 / 7.4.1 / 8.2.0 の3つを作るが、**開発・動作確認は基本的に 7.4.1 で行う**。
  スクリプトの例やテストは 7.4.1 を基準にする。
- 6.0 / 8.2.0 用のスクリプトは同じ仕組みで用意しておき、7.4.1 で確認した変更を同じように反映する。
  なお、6.0 は FREESURFER_HOME やライセンスの扱いが違い、8.2.0 はメモリを多く使う (`MEM_PER_JOB` 12GB 以上)。

### Singularity イメージ

- 定義ファイル: `containers/singularity/freesurfer_<ver>_parallel.def` (6.0 / 7.4.1 / 8.2.0。中身は Docker 版の Dockerfile と同じ)
- ビルド: `containers/singularity/build.sh`。マスターノードで `--fakeroot` を使ってビルドできる (既定で付く)。
- 保存先: `containers/singularity/freesurfer_<ver>_parallel.sif` (`.sif` は git 管理外)

### スクリプト (`scripts/singularity/`)

| ファイル | 役割 |
|---|---|
| `submit_openbhb_train_<ver>.sh` | 入口。バージョンごとの既定値 (ノード数、CPU 数、`MEM_PER_JOB` など) を設定して `submit_recon.sh` を呼ぶ |
| `submit_recon.sh` | マスターで実行。被験者を列挙し、完了済みを除き、`NUM_NODES` 個のリストにラウンドロビンで分けて `sbatch --array` で投入する |
| `recon_array_job.sh` | 配列タスク1つ (1ノード) の処理。担当リストを `singularity exec ... parallel` で処理する |
| `recon_worker.sh` | 被験者1人分の recon-all (Singularity 版専用。`hostname` の代わりを用意する点が Docker 版と違う) |
| `check_status.sh` | 状態の一覧 (Singularity 版専用。Slurm のジョブと照らして running / interrupted を判定する) |
| `README.md` | Singularity 版の使い方 |

### 実行中のジョブがあるときのスクリプト変更

- `scripts/singularity/recon_worker.sh` はコンテナにファイル単位で bind され、bash は実行しながら少しずつ読み進める。
  **実行中に同じファイルをその場で書き換えると (エディタの上書き保存、`sed -i` 以外の in-place 書き込み等)、recon-all 終了後に worker がずれた位置から読んで誤動作する。**
  変更するときは、別ファイルに書いてから `mv` で差し替える (inode が変わるので、実行中のジョブは古い中身を読み続ける)。
- `recon_array_job.sh` は sbatch 時に Slurm がコピーするので、投入後に変更しても実行中のジョブには影響しない。

### イメージ・コンテナの注意

- 7.4.1 / 8.2.0 のベースイメージ (RHEL 系) には `hostname` コマンドが無い。recon-all が `IsRunning.*` の `HOST` を空で書き、`check_status.sh` が実行中か判定できなくなる。
  def で `hostname` パッケージを入れる (要再ビルド)。古いイメージでも動くよう `scripts/singularity/recon_worker.sh` が代わりのコマンドを用意する。
- singularity-ce では `--env HOME=...` で HOME を上書きできない (警告が出て無視される)。`--home /tmp` を使う。

### パス

| 用途 | パス |
|---|---|
| 入力 (OpenBHB) | `/dataset02/mri_data/openBHB` (**各計算ノードのローカルディスク**。全ノードに同じデータがある) |
| 出力 (`SUBJECTS_DIR`) | `/shared_datasets/BrainMRIDatasets/fs_output/openBHB/<split>/freesurfer_<ver>/` (NFS。Docker 版と同じ命名規則) |
| 投入ごとのログ | `<SUBJECTS_DIR>/_logs/run_<日時>/` (`run_info.txt`, `lists/node_NNN.txt`, `slurm/`, `joblog/`, `results/`) |
| ライセンス | `fs_license/license.txt` (git 管理外) |

### クラスタの注意点 (2026-11-24 に確認)

- 計算ノードはすべて GPU ノード (40〜128 コア、240〜980GB)。パーティションの上限は 7日 (rtx8000 は 28日)。
- `SelectTypeParameters=CR_CPU` で、ジョブの cgroup の `memory.max` も `max`。**`--mem` を指定してもメモリは確保も制限もされない**。
  同じノードの他のジョブとメモリを取り合うので、`JOBS × MEM_PER_JOB` に余裕を持たせる (必要なら `EXCLUSIVE=1` や `MEMFREE`)。
- Slurm の CPU 数は論理コア (ハイパースレッド込み)。`-c 1` で `nproc` が 2 になる。
- `srun` は interactive パーティションでしか使えない。ジョブスクリプト内では `srun` を使わず、`singularity exec` を直接呼ぶ。
- `/home` は使用率 85%。大きな出力は `/shared_datasets` に置く。
- 2026-11-24 に node02 の `/shared_datasets` が読み取り専用 (ro) になっていた (管理者が修正済み)。あるノードから出力先に書けないと、Slurm の出力ファイルも作れず、ジョブは即 FAILED (ExitCode 0:53) になりログも残らない。
  その場合は `EXCLUDE_NODES` でそのノードを除外する。`recon_array_job.sh` は開始時に出力先へ書き込めるかを確認する。

## MRIのデータセットのパスと構造

### OpenBHB Dataset（`openBHB`までのパスは環境によって異なる）

```
/path/to/openBHB/ 
├── README.md
├── participants.tsv # meta-data relative to subjects and scans, e.g. age, sex, site label
├── qc.tsv # quality check metrics, e.g. Euler number
├── train/
    ├──derivatives/
        ├──sub-*
            ├──ses-1
                ├── sub-*_preproc-quasiraw_T1w.npy          # quasi-raw 3D volume
                ├── sub-*_preproc-cat12vbm_desc-gm_T1w.npy  # cat12 3D volume
                ├── sub-*_preproc-cat12vbm_desc-gm_ROI.npy       # gray matter volume on Neuromorphometric atlas
                ├── sub-*_preproc-freesurfer_desc-xhemi_T1w.npy  # surface-based features on mesh
                ├── sub-*_preproc-freesurfer_desc-desikan_ROI.npy # surface-based features on Desikan atlas
                ├── sub-*_preproc-freesurfer_desc-destrieux_ROI.npy # surface-based features on Destrieux atlas
        ├──cat12vbm_roi/
            cat12vbm_roi_features.csv   # GM volume on Neuromorphometric atlas concatenated across subjects
        ├──freesurfer_roi/
            desikan_roi_features.csv    # surface-based features on Desikan atlas concatenated across subjects
            destrieux_roi_features.csv  # surface-based features on Destrieux atlas concatenated across subjects
    ├──rawdata/
        ├──sub-*
            ├──ses-1
                ├── sub-*_T1w.nii # raw T1 MRI
├── val/
    ├──derivatives/
        ├──sub-*
            ...  # same structure as 'train'
    ├──rawdata/
        ├──sub-*
            ... # same structure as 'train'
├── resource/
    ├── cat12vbm_space-MNI152_desc-gm_TPM.nii.gz  # template used in CAT12 co-registration
    ├── quasiraw_space-MNI152_desc-brain_T1w.nii.gz # template used in quasi-raw co-registration
    ├── cat12vbm_labels.txt  # ROI names for Neuromorphometric atlas
    ├── freesurfer_atlas-desikan_labels.txt # ROI names for Desikan atlas
    ├── freesurfer_atlas-destrieux_labels.txt # ROI names for Destrieux atlas
    ├── freesurfer_channels.txt # Feature names derived by FreeSurfer on Destrieux/Desikan atlas
    ├── freesurfer_xhemi_channels.txt 
    ├── neuromorphometrics.csv  # Neuromorphometric labels
    ├── neuromorphometrics.nii  # Neuromorphometric atlas
    ├── resources.json  # meta-data info on numpy arrays
```
