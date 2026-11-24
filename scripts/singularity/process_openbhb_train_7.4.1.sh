#!/bin/bash
#SBATCH --job-name=bhb_train_7.4.1
#SBATCH --nodes=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=48G
#SBATCH --time=72:00:00
#SBATCH --output=slurm-%x-%A_%a.out
# OpenBHB train を FreeSurfer 7.4.1 (Singularity + Slurm) で処理する。recon-all を GNU Parallel で並列実行。
#   sbatch scripts/singularity/process_openbhb_train_7.4.1.sh                # 1ノード
#   sbatch --array=0-9 scripts/singularity/process_openbhb_train_7.4.1.sh    # 10ノードに被験者を自動分割
#   LIMIT=1 sbatch --export=ALL,LIMIT=1 ...                                      # 先頭1人だけ (テスト)
#   DRY_RUN=1 bash scripts/singularity/process_openbhb_train_7.4.1.sh        # コマンド確認のみ (Slurm不要)
# ※ sbatch はプロジェクトのルートディレクトリで実行すること (または PROJECT_DIR を指定)。
# ※ #SBATCH の資源はクラスタに合わせて編集するか、sbatch のオプションで上書きする。
set -euo pipefail

# ------------------ パラメータ (環境変数で上書き可) ------------------
FS_VERSION="7.4.1"
SPLIT="train"
THREADS_PER_JOB="${THREADS_PER_JOB:-1}"                      # recon-all -openmp の値
JOBS="${JOBS:-$(( ${SLURM_CPUS_PER_TASK:-8} / THREADS_PER_JOB ))}"  # 同時実行する被験者数 (Slurm のコア数から自動)
RECON_FLAGS="${RECON_FLAGS:--all}"                           # recon-all の追加オプション
JOB_TIMEOUT="${JOB_TIMEOUT:-24h}"                            # 1人あたりの制限時間 (例: 24h, 36h, 90m。0 で無制限)
RETRY_TIMEOUT="${RETRY_TIMEOUT:-0}"                          # 1 なら前回時間切れの被験者もやり直す
LIMIT="${LIMIT:-0}"                                          # 0=全員 / N=先頭N人
DRY_RUN="${DRY_RUN:-0}"
PROJECT_DIR="${PROJECT_DIR:-${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
SIF_IMAGE="${SIF_IMAGE:-${PROJECT_DIR}/containers/singularity/freesurfer_${FS_VERSION}_parallel.sif}"
FS_LICENSE_FILE="${FS_LICENSE_FILE:-${PROJECT_DIR}/fs_license/license.txt}"
DATA_ROOT="${DATA_ROOT:-/raid/hirakawa/datasets/openBHB}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/raid/hirakawa/fs_output}"
SINGULARITY_BIN="${SINGULARITY_BIN:-$(command -v apptainer || command -v singularity || echo singularity)}"
# 配列ジョブなら被験者を自動分割 (手動なら SHARD_COUNT / SHARD_INDEX を指定)
SHARD_COUNT="${SHARD_COUNT:-${SLURM_ARRAY_TASK_COUNT:-1}}"
SHARD_INDEX="${SHARD_INDEX:-$(( ${SLURM_ARRAY_TASK_ID:-0} - ${SLURM_ARRAY_TASK_MIN:-0} ))}"
# ---------------------------------------------------------------------

RAW_DIR="${DATA_ROOT}/${SPLIT}/rawdata"
OUT_DIR="${OUTPUT_ROOT}/openBHB/${SPLIT}/freesurfer_${FS_VERSION}"
WORKER="${PROJECT_DIR}/scripts/recon_worker.sh"
TAG=$([ "$SHARD_COUNT" -gt 1 ] && echo "_shard${SHARD_INDEX}" || echo "")   # ログ名の接尾辞

[ -d "$RAW_DIR" ] || { echo "ERROR: $RAW_DIR not found" >&2; exit 1; }
if [ "$DRY_RUN" != "1" ]; then
    [ -f "$FS_LICENSE_FILE" ] || { echo "ERROR: license not found: $FS_LICENSE_FILE" >&2; exit 1; }
    [ -f "$SIF_IMAGE" ] || { echo "ERROR: SIF not found: $SIF_IMAGE (containers/singularity/build.sh)" >&2; exit 1; }
fi

# 被験者リスト (T1w が存在するもの) → LIMIT → 担当分だけ抽出
SUBJ_LIST="$(mktemp)"; trap 'rm -f "$SUBJ_LIST" "$SUBJ_LIST".*' EXIT
for d in "$RAW_DIR"/sub-*; do
    s="$(basename "$d")"
    ls "$d"/ses-1/${s}_T1w.nii* >/dev/null 2>&1 && echo "$s" || echo "WARN: no T1w for $s" >&2
done > "$SUBJ_LIST"
[ "$LIMIT" -gt 0 ] && { head -n "$LIMIT" "$SUBJ_LIST" > "$SUBJ_LIST.h"; mv "$SUBJ_LIST.h" "$SUBJ_LIST"; }
awk -v n="$SHARD_COUNT" -v i="$SHARD_INDEX" '(NR-1)%n==i' "$SUBJ_LIST" > "$SUBJ_LIST.s"; mv "$SUBJ_LIST.s" "$SUBJ_LIST"
echo "Singularity FS=$FS_VERSION split=$SPLIT shard=${SHARD_INDEX}/${SHARD_COUNT} subjects=$(wc -l < "$SUBJ_LIST") jobs=$JOBS timeout=$JOB_TIMEOUT -> $OUT_DIR"

# CPU/メモリの制限は Slurm (cgroup) が行う。--cleanenv でホスト環境変数を持ち込まない。
CMD=("$SINGULARITY_BIN" exec --cleanenv
    --env HOME=/tmp --env FS_LICENSE=/fs_license/license.txt
    --env RECON_FLAGS="$RECON_FLAGS" --env THREADS_PER_JOB="$THREADS_PER_JOB"
    --env JOB_TIMEOUT="$JOB_TIMEOUT" --env RETRY_TIMEOUT="$RETRY_TIMEOUT"
    --bind "$RAW_DIR":/input:ro --bind "$OUT_DIR":/output
    --bind "$FS_LICENSE_FILE":/fs_license/license.txt:ro
    --bind "$SUBJ_LIST":/subjects.txt:ro --bind "$WORKER":/worker.sh:ro
    "$SIF_IMAGE"
    parallel --jobs "$JOBS" --joblog "/output/_logs/joblog${TAG}.txt" --results "/output/_logs/results${TAG}"
             --line-buffer bash /worker.sh {} :::: /subjects.txt)

if [ "$DRY_RUN" = "1" ]; then
    printf '%q ' "${CMD[@]}"; echo; exit 0
fi
mkdir -p "$OUT_DIR/_logs"
"${CMD[@]}"
