#!/bin/bash
# OpenBHB train を FreeSurfer 8.2.0 (Docker) で処理する。recon-all を GNU Parallel で並列実行。
#   ./process_openbhb_train_8.2.0.sh            # 実行
#   DRY_RUN=1 ./process_openbhb_train_8.2.0.sh  # コマンド確認のみ
#   LIMIT=1 ./process_openbhb_train_8.2.0.sh    # 先頭1人だけ (テスト)
set -euo pipefail

# ------------------ パラメータ (環境変数で上書き可) ------------------
FS_VERSION="8.2.0"
SPLIT="train"
JOBS="${JOBS:-8}"                        # 同時実行する被験者数
MEM_PER_JOB="${MEM_PER_JOB:-6}"          # 1ジョブあたりのメモリ(GB)
THREADS_PER_JOB="${THREADS_PER_JOB:-1}"  # recon-all -openmp の値
RECON_FLAGS="${RECON_FLAGS:--all}"       # recon-all の追加オプション
JOB_TIMEOUT="${JOB_TIMEOUT:-24h}"        # 1人あたりの制限時間 (例: 24h, 36h, 90m。0 で無制限)
RETRY_TIMEOUT="${RETRY_TIMEOUT:-0}"      # 1 なら前回時間切れの被験者もやり直す
LIMIT="${LIMIT:-0}"                      # 0=全員 / N=先頭N人
DRY_RUN="${DRY_RUN:-0}"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DOCKER_IMAGE="${DOCKER_IMAGE:-freesurfer:${FS_VERSION}-parallel}"
FS_LICENSE_FILE="${FS_LICENSE_FILE:-${PROJECT_DIR}/fs_license/license.txt}"
DATA_ROOT="${DATA_ROOT:-/raid/hirakawa/datasets/openBHB}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/raid/hirakawa/fs_output}"
# ---------------------------------------------------------------------

RAW_DIR="${DATA_ROOT}/${SPLIT}/rawdata"
OUT_DIR="${OUTPUT_ROOT}/openBHB/${SPLIT}/freesurfer_${FS_VERSION}"
WORKER="${PROJECT_DIR}/scripts/recon_worker.sh"

[ -d "$RAW_DIR" ] || { echo "ERROR: $RAW_DIR not found" >&2; exit 1; }
[ "$DRY_RUN" = "1" ] || [ -f "$FS_LICENSE_FILE" ] || { echo "ERROR: license not found: $FS_LICENSE_FILE" >&2; exit 1; }

# 被験者リスト (T1w が存在するもの)
SUBJ_LIST="$(mktemp)"; trap 'rm -f "$SUBJ_LIST"' EXIT
for d in "$RAW_DIR"/sub-*; do
    s="$(basename "$d")"
    ls "$d"/ses-1/${s}_T1w.nii* >/dev/null 2>&1 && echo "$s" || echo "WARN: no T1w for $s" >&2
done > "$SUBJ_LIST"
[ "$LIMIT" -gt 0 ] && { head -n "$LIMIT" "$SUBJ_LIST" > "$SUBJ_LIST.h"; mv "$SUBJ_LIST.h" "$SUBJ_LIST"; }
echo "Docker FS=$FS_VERSION split=$SPLIT subjects=$(wc -l < "$SUBJ_LIST") jobs=$JOBS timeout=$JOB_TIMEOUT mem/job=${MEM_PER_JOB}G -> $OUT_DIR"

CMD=(docker run --rm
    --user "$(id -u):$(id -g)"
    --memory "$((JOBS*MEM_PER_JOB))g" --cpus "$((JOBS*THREADS_PER_JOB))"
    -e HOME=/tmp -e FS_LICENSE=/usr/local/freesurfer/license.txt
    -e RECON_FLAGS="$RECON_FLAGS" -e THREADS_PER_JOB="$THREADS_PER_JOB"
    -e JOB_TIMEOUT="$JOB_TIMEOUT" -e RETRY_TIMEOUT="$RETRY_TIMEOUT"
    -v "$RAW_DIR":/input:ro -v "$OUT_DIR":/output
    -v "$FS_LICENSE_FILE":/usr/local/freesurfer/license.txt:ro
    -v "$SUBJ_LIST":/subjects.txt:ro -v "$WORKER":/worker.sh:ro
    "$DOCKER_IMAGE"
    parallel --jobs "$JOBS" --joblog /output/_logs/joblog.txt --results /output/_logs/results
             --line-buffer bash /worker.sh {} :::: /subjects.txt)

if [ "$DRY_RUN" = "1" ]; then
    printf '%q ' "${CMD[@]}"; echo; exit 0
fi
mkdir -p "$OUT_DIR/_logs"
"${CMD[@]}"
