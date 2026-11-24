#!/bin/bash
# Slurm + Singularity で recon-all を複数ノードに分けて実行する (共通の投入スクリプト)。
# 直接ではなく submit_<dataset>_<split>_<ver>.sh から呼ぶ。マスターノードで bash として実行する (sbatch しない)。
#
# 流れ:
#   1. RAW_DIR の被験者 (T1w があるもの) を列挙し、完了済み・時間切れの被験者を除く
#   2. 残りを NUM_NODES 個のリストにラウンドロビンで分ける
#      (<OUT_DIR>/_logs/run_<日時>/lists/node_000.txt, node_001.txt, ...)
#   3. sbatch --array=0-(NUM_NODES-1) で recon_array_job.sh を投入する
#      配列タスク i が node_<i>.txt を担当し、ノード内では GNU Parallel で JOBS 人を同時に処理する
#
# 中断・失敗した被験者は、同じスクリプトを再実行すればもう一度リストに入る (完了済みは入らない)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# ------------------ パラメータ (環境変数で上書き可) ------------------
: "${FS_VERSION:?FS_VERSION is required}"
: "${DATASET:?DATASET is required}"                          # 出力パスに使う (例: openBHB)
: "${SPLIT:?SPLIT is required}"                              # train / val
: "${DATA_ROOT:?DATA_ROOT is required}"                      # データセットのルート (計算ノードから同じパスで見えること)
RAW_DIR="${RAW_DIR:-${DATA_ROOT}/${SPLIT}/rawdata}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/shared_datasets/BrainMRIDatasets/fs_output}"   # 共有ストレージ (NFS) であること
OUT_DIR="${OUT_DIR:-${OUTPUT_ROOT}/${DATASET}/${SPLIT}/freesurfer_${FS_VERSION}}"

# --- Slurm の資源 ---
NUM_NODES="${NUM_NODES:-8}"                # 分割数 = 配列タスク数 (1タスク = 1ノード分)
CPUS_PER_NODE="${CPUS_PER_NODE:-32}"       # 1タスクの CPU 数 (--cpus-per-task)。論理コア数 (ハイパースレッド込み)
THREADS_PER_JOB="${THREADS_PER_JOB:-1}"    # recon-all -openmp の値
JOBS="${JOBS:-$(( CPUS_PER_NODE / THREADS_PER_JOB ))}"   # 1ノードで同時に処理する被験者数
MEM_PER_JOB="${MEM_PER_JOB:-6}"            # 1被験者あたりのメモリ (GB)。--mem = JOBS × MEM_PER_JOB
PARTITION="${PARTITION:-a6000_ada}"
TIME_LIMIT="${TIME_LIMIT:-7-00:00:00}"     # 1タスクの制限時間 (パーティションの上限は 7日)
MAX_CONCURRENT="${MAX_CONCURRENT:-}"       # 同時に動かす配列タスク数の上限 (--array=...%N)。空なら制限なし
EXCLUDE_NODES="${EXCLUDE_NODES:-}"         # 使わないノード (--exclude。例: node01,node02)
EXCLUSIVE="${EXCLUSIVE:-0}"                # 1 ならノードを専有 (--exclusive)
EXTRA_SBATCH_OPTS="${EXTRA_SBATCH_OPTS:-}" # その他の sbatch オプション (例: "--nodelist=node05")
JOB_NAME="${JOB_NAME:-fs${FS_VERSION}_${DATASET}_${SPLIT}}"

# --- recon-all / GNU Parallel ---
RECON_FLAGS="${RECON_FLAGS:--all}"         # recon-all の追加オプション
JOB_TIMEOUT="${JOB_TIMEOUT:-24h}"          # 1人あたりの制限時間 (例: 24h, 36h, 90m。0 で無制限)
RETRY_TIMEOUT="${RETRY_TIMEOUT:-0}"        # 1 なら前回時間切れの被験者もやり直す
START_DELAY="${START_DELAY:-30}"           # ノード内でジョブを開始する間隔 (秒, parallel --delay)。序盤の重いステップの重なりを減らす
MEMFREE="${MEMFREE:-0}"                    # >0 なら空きメモリが MEMFREE GB 未満のとき次の被験者を始めない (parallel --memfree)
LIMIT="${LIMIT:-0}"                        # 0=全員 / N=先頭N人 (テスト用)
DRY_RUN="${DRY_RUN:-0}"                    # 1 なら投入せず、分割結果と sbatch コマンドを表示するだけ
FORCE_SUBMIT="${FORCE_SUBMIT:-0}"          # 1 なら同名ジョブが動いていても投入する

SIF_IMAGE="${SIF_IMAGE:-${PROJECT_DIR}/containers/singularity/freesurfer_${FS_VERSION}_parallel.sif}"
FS_LICENSE_FILE="${FS_LICENSE_FILE:-${PROJECT_DIR}/fs_license/license.txt}"
SINGULARITY_BIN="${SINGULARITY_BIN:-$(command -v singularity || command -v apptainer || echo singularity)}"
# ---------------------------------------------------------------------

WORKER="${SCRIPT_DIR}/recon_worker.sh"
JOB_SCRIPT="${SCRIPT_DIR}/recon_array_job.sh"

die() { echo "ERROR: $*" >&2; exit 1; }
[ -d "$RAW_DIR" ] || die "$RAW_DIR not found"
[ -f "$WORKER" ] || die "$WORKER not found"
[ -f "$JOB_SCRIPT" ] || die "$JOB_SCRIPT not found"
[ "$JOBS" -ge 1 ] || die "JOBS=$JOBS (CPUS_PER_NODE / THREADS_PER_JOB が 1 未満)"
if [ "$DRY_RUN" != "1" ]; then
    command -v sbatch >/dev/null || die "sbatch not found (Slurm のマスターノードで実行する)"
    [ -f "$FS_LICENSE_FILE" ] || die "license not found: $FS_LICENSE_FILE"
    [ -f "$SIF_IMAGE" ] || die "SIF not found: $SIF_IMAGE (containers/singularity/build.sh でビルドする)"
    if [ "$FORCE_SUBMIT" != "1" ] && [ -n "$(squeue -h -u "$USER" -n "$JOB_NAME" -o %i 2>/dev/null)" ]; then
        die "同名のジョブ ($JOB_NAME) が投入済み・実行中。同じ被験者を二重に処理しないよう中止した (squeue -u $USER で確認。承知の上なら FORCE_SUBMIT=1)"
    fi
fi

# ---- 1. 被験者リスト (recon_worker.sh / check_status.sh と同じ基準で完了・時間切れを除く) ----
state_of() {
    local sc="$OUT_DIR/$1/scripts"
    if [ -f "$sc/recon-all.done" ] && grep -q '^END_TIME' "$sc/recon-all.done" \
       && { [ ! -f "$sc/recon-all.error" ] || [ "$sc/recon-all.done" -nt "$sc/recon-all.error" ]; }; then
        echo done
    elif [ -f "$sc/recon-all.timeout" ] && [ "$RETRY_TIMEOUT" != "1" ]; then
        echo timeout
    else
        echo todo
    fi
}

TMP_LIST="$(mktemp)"; trap 'rm -f "$TMP_LIST"' EXIT
n_all=0; n_done=0; n_timeout=0; n_missing=0
for d in "$RAW_DIR"/sub-*; do
    [ -d "$d" ] || continue
    s="$(basename "$d")"
    if ! ls "$d"/ses-1/"${s}"_T1w.nii* >/dev/null 2>&1; then
        echo "WARN: no T1w for $s" >&2; n_missing=$((n_missing + 1)); continue
    fi
    n_all=$((n_all + 1))
    [ "$LIMIT" -gt 0 ] && [ "$n_all" -gt "$LIMIT" ] && { n_all=$((n_all - 1)); break; }
    case "$(state_of "$s")" in
        done) n_done=$((n_done + 1)) ;;
        timeout) n_timeout=$((n_timeout + 1)) ;;
        *) echo "$s" >> "$TMP_LIST" ;;
    esac
done
n_todo=$(wc -l < "$TMP_LIST")
echo "FS=$FS_VERSION $DATASET/$SPLIT: subjects=$n_all (done=$n_done, timeout(skip)=$n_timeout, todo=$n_todo)$( [ "$LIMIT" -gt 0 ] && echo " LIMIT=$LIMIT")"
echo "  RAW_DIR=$RAW_DIR"
echo "  OUT_DIR=$OUT_DIR"
[ "$n_todo" -gt 0 ] || { echo "処理する被験者はいない。"; exit 0; }

# ---- 2. ノード数に分割 (ラウンドロビン。同じサイトの被験者が1ノードに偏らないように) ----
N=$NUM_NODES; [ "$N" -gt "$n_todo" ] && N=$n_todo
RUN_ID="run_$(date +%Y%m%d_%H%M%S)"
if [ "$DRY_RUN" = "1" ]; then
    RUN_DIR="$(mktemp -d)"; trap 'rm -f "$TMP_LIST"; rm -rf "$RUN_DIR"' EXIT
else
    RUN_DIR="$OUT_DIR/_logs/$RUN_ID"
fi
mkdir -p "$RUN_DIR/lists" "$RUN_DIR/slurm" "$RUN_DIR/joblog" "$RUN_DIR/results"
awk -v n="$N" -v dir="$RUN_DIR/lists" '{ f = sprintf("%s/node_%03d.txt", dir, (NR-1)%n); print > f }' "$TMP_LIST"
per_node=$(( (n_todo + N - 1) / N ))
rounds=$(( (per_node + JOBS - 1) / JOBS ))
echo "  分割: $N ノード × 最大 $per_node 人, 1ノード $JOBS 並列 → 約 $rounds 巡 (1人 6〜10時間なら約 $((rounds * 6))〜$((rounds * 10)) 時間)"

# ---- 3. 投入 ----
MEM_PER_NODE=$(( JOBS * MEM_PER_JOB ))
array="0-$((N - 1))${MAX_CONCURRENT:+%$MAX_CONCURRENT}"
SBATCH=(sbatch --parsable
    --job-name="$JOB_NAME" --partition="$PARTITION" --array="$array"
    --nodes=1 --ntasks=1 --cpus-per-task="$CPUS_PER_NODE" --mem="${MEM_PER_NODE}G" --time="$TIME_LIMIT"
    --output="$RUN_DIR/slurm/slurm_%A_%a.out"
    --export=ALL)
[ -n "$EXCLUDE_NODES" ] && SBATCH+=(--exclude="$EXCLUDE_NODES")
[ "$EXCLUSIVE" = "1" ] && SBATCH+=(--exclusive)
# shellcheck disable=SC2206
[ -n "$EXTRA_SBATCH_OPTS" ] && SBATCH+=($EXTRA_SBATCH_OPTS)
SBATCH+=("$JOB_SCRIPT")

# recon_array_job.sh に渡す変数 (--export=ALL で引き継ぐ)
export FS_VERSION RAW_DIR OUT_DIR RUN_DIR SIF_IMAGE FS_LICENSE_FILE WORKER SINGULARITY_BIN \
       JOBS THREADS_PER_JOB MEM_PER_JOB RECON_FLAGS JOB_TIMEOUT RETRY_TIMEOUT START_DELAY MEMFREE

if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY_RUN] 各ノードの担当人数:"
    for f in "$RUN_DIR"/lists/node_*.txt; do printf '    %s %5d 人 (先頭: %s)\n' "$(basename "$f")" "$(wc -l < "$f")" "$(head -n1 "$f")"; done
    echo "[DRY_RUN] 投入コマンド (RUN_DIR は本番では $OUT_DIR/_logs/$RUN_ID):"
    printf '    '; printf '%q ' "${SBATCH[@]}"; echo
    exit 0
fi

{
    echo "run_id      $RUN_ID"
    echo "submitted   $(date '+%Y-%m-%d %H:%M:%S %Z') by $USER on $(hostname)"
    echo "fs_version  $FS_VERSION"
    echo "raw_dir     $RAW_DIR"
    echo "out_dir     $OUT_DIR"
    echo "sif_image   $SIF_IMAGE"
    echo "subjects    all=$n_all done=$n_done timeout_skip=$n_timeout todo=$n_todo limit=$LIMIT"
    echo "nodes       $N (partition=$PARTITION cpus=$CPUS_PER_NODE mem=${MEM_PER_NODE}G time=$TIME_LIMIT array=$array)"
    echo "parallel    jobs=$JOBS threads=$THREADS_PER_JOB mem_per_job=${MEM_PER_JOB}G delay=${START_DELAY}s memfree=${MEMFREE}G"
    echo "recon       flags=$RECON_FLAGS timeout=$JOB_TIMEOUT retry_timeout=$RETRY_TIMEOUT"
    printf 'sbatch      '; printf '%q ' "${SBATCH[@]}"; echo
} > "$RUN_DIR/run_info.txt"

jobid="$("${SBATCH[@]}")"
echo "jobid       $jobid" >> "$RUN_DIR/run_info.txt"
echo "投入しました: job $jobid (array $array)"
echo "  ログ: $RUN_DIR"
echo "        run_info.txt (投入内容) / slurm/slurm_${jobid}_<タスク番号>.out (各ノードの出力) / joblog/ / results/"
echo "  ※ slurm/*.out が作られずに FAILED (ExitCode 0:53) になったら、そのノードから出力先に書き込めていない。"
echo "     sacct -j $jobid -o JobID,State,NodeList,ExitCode で確認し、EXCLUDE_NODES にそのノードを加える"
echo "  確認: squeue -u $USER -n $JOB_NAME ;  scripts/singularity/check_status.sh $OUT_DIR"
