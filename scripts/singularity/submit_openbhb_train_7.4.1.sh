#!/bin/bash
# OpenBHB train (3227人) を FreeSurfer 7.4.1 で処理する (Slurm + Singularity)。
# マスターノードで bash として実行する (sbatch しない)。被験者を NUM_NODES 個に分け、sbatch --array で投入する。
#   scripts/singularity/submit_openbhb_train_7.4.1.sh                     # 投入
#   DRY_RUN=1 scripts/singularity/submit_openbhb_train_7.4.1.sh           # 分割結果と sbatch コマンドの確認のみ
#   LIMIT=2 NUM_NODES=1 scripts/singularity/submit_openbhb_train_7.4.1.sh # 先頭2人だけ1ノードで (テスト)
#   NUM_NODES=4 CPUS_PER_NODE=64 scripts/singularity/submit_openbhb_train_7.4.1.sh   # 資源を変える
# 再実行すると、完了済みの被験者を除いた残りだけを分割して投入する。
# パラメータの一覧は scripts/singularity/submit_recon.sh を参照。
# 7.4.1: 1プロセスのピーク約 2.1GB (実測)。1人 平均約 6.5時間 (val 実測)。
set -euo pipefail

# ------------------ パラメータ (環境変数で上書き可) ------------------
export FS_VERSION="7.4.1"
export DATASET="openBHB"
export SPLIT="train"
export DATA_ROOT="${DATA_ROOT:-/dataset02/mri_data/openBHB}"              # 各計算ノードのローカルディスク
export OUTPUT_ROOT="${OUTPUT_ROOT:-/shared_datasets/BrainMRIDatasets/fs_output}"  # 共有ストレージ (NFS)
export NUM_NODES="${NUM_NODES:-8}"              # 使用するノード数 (= 配列タスク数)
export CPUS_PER_NODE="${CPUS_PER_NODE:-32}"     # 1ノードあたりの CPU 数。同時処理数 JOBS = CPUS_PER_NODE / THREADS_PER_JOB
export MEM_PER_JOB="${MEM_PER_JOB:-4}"           # 1被験者あたりのメモリ (GB)
export PARTITION="${PARTITION:-a6000_ada}"
export TIME_LIMIT="${TIME_LIMIT:-7-00:00:00}"   # 1ノード (配列タスク) の制限時間
export EXCLUDE_NODES="${EXCLUDE_NODES:-}"      # 使わないノード (--exclude。例: node01,node02)。空なら除外しない
export JOB_TIMEOUT="${JOB_TIMEOUT:-24h}"        # 1被験者の制限時間
# ---------------------------------------------------------------------

exec bash "$(dirname "${BASH_SOURCE[0]}")/submit_recon.sh"
