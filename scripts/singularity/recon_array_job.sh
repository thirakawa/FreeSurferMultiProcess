#!/bin/bash
# Slurm の配列タスク1つ (= 1ノード) で、担当する被験者リストを GNU Parallel で処理する。
# submit_recon.sh が sbatch で投入する。直接実行・直接 sbatch はしない (必要な変数は submit_recon.sh が渡す)。
#
# 担当リスト: $RUN_DIR/lists/node_<SLURM_ARRAY_TASK_ID (3桁)>.txt
# ログ      : $RUN_DIR/joblog/node_<id>.txt   (GNU Parallel のジョブログ。終了コード・所要時間)
#             $RUN_DIR/results/node_<id>/     (被験者ごとの stdout / stderr)
#             $RUN_DIR/slurm/slurm_<jobid>_<id>.out (このスクリプトの出力)
# srun は使わない (このクラスタでは interactive パーティション以外で srun が拒否される)。
set -euo pipefail

for v in RUN_DIR RAW_DIR OUT_DIR SIF_IMAGE FS_LICENSE_FILE WORKER SINGULARITY_BIN JOBS THREADS_PER_JOB \
         MEM_PER_JOB RECON_FLAGS JOB_TIMEOUT RETRY_TIMEOUT START_DELAY MEMFREE; do
    [ -n "${!v+x}" ] || { echo "ERROR: $v is not set (submit_recon.sh から投入すること)" >&2; exit 2; }
done

ID="$(printf '%03d' "${SLURM_ARRAY_TASK_ID:?not an array job}")"
LIST="$RUN_DIR/lists/node_${ID}.txt"
[ -f "$LIST" ] || { echo "ERROR: $LIST not found" >&2; exit 2; }
[ -d "$RAW_DIR" ] || { echo "ERROR: $RAW_DIR not found on $(hostname)" >&2; exit 2; }
mkdir -p "$OUT_DIR" 2>/dev/null || true
# 出力先に書き込めるか (ノードによっては /shared_datasets が読み取り専用でマウントされている)
if ! touch "$OUT_DIR/.write_test_$(hostname)" 2>/dev/null; then
    echo "ERROR: $(hostname) から $OUT_DIR に書き込めない (読み取り専用?)。EXCLUDE_NODES にこのノードを加えて再投入する" >&2; exit 2
fi
rm -f "$OUT_DIR/.write_test_$(hostname)"

# 空きメモリの確認 (このクラスタは Slurm がメモリを確保・制限しないので、他のジョブと取り合いになりうる)
need_gb=$(( JOBS * MEM_PER_JOB ))
avail_gb=$(( $(awk '/^MemAvailable/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
echo "[$(date '+%F %T')] host=$(hostname) job=${SLURM_ARRAY_JOB_ID:-?}_${SLURM_ARRAY_TASK_ID} list=$(basename "$LIST") subjects=$(wc -l < "$LIST")"
echo "  cpus=${SLURM_CPUS_PER_TASK:-?} jobs=$JOBS threads/job=$THREADS_PER_JOB mem: need~${need_gb}G avail=${avail_gb}G timeout=$JOB_TIMEOUT"
[ "$avail_gb" -ge "$need_gb" ] || echo "WARN: ノードの空きメモリ (${avail_gb}G) が JOBS × MEM_PER_JOB (${need_gb}G) より少ない。Killed (メモリ不足) で失敗する可能性がある" >&2

PAR_OPTS=(--jobs "$JOBS" --delay "$START_DELAY" --line-buffer
          --joblog "/run_dir/joblog/node_${ID}.txt" --results "/run_dir/results/node_${ID}")
[ "$MEMFREE" != "0" ] && PAR_OPTS+=(--memfree "${MEMFREE}G")

# --cleanenv でホストの環境変数を持ち込まない。HOME は --home で計算ノードのローカル /tmp にする
# (singularity-ce では --env HOME=... で HOME を上書きできない)。
# FS_LICENSE は 7.4.1 / 8.2.0 用。6.0 はイメージ内の /opt/freesurfer/license.txt -> /fs_license/license.txt を読む。
set +e
"$SINGULARITY_BIN" exec --cleanenv --home /tmp --pwd /tmp \
    --env FS_LICENSE=/fs_license/license.txt \
    --env RECON_FLAGS="$RECON_FLAGS" --env THREADS_PER_JOB="$THREADS_PER_JOB" \
    --env JOB_TIMEOUT="$JOB_TIMEOUT" --env RETRY_TIMEOUT="$RETRY_TIMEOUT" \
    --bind "$RAW_DIR":/input:ro --bind "$OUT_DIR":/output --bind "$RUN_DIR":/run_dir \
    --bind "$FS_LICENSE_FILE":/fs_license/license.txt:ro \
    --bind "$WORKER":/worker.sh:ro --bind "$LIST":/subjects.txt:ro \
    "$SIF_IMAGE" \
    parallel "${PAR_OPTS[@]}" bash /worker.sh {} :::: /subjects.txt
rc=$?
set -e

# 終了コードの集計 (joblog の 7列目 Exitval)
echo "[$(date '+%F %T')] parallel exit=$rc  (0 以外のジョブ数。内訳: Exitval 件数)"
awk -F'\t' 'NR>1 {c[$7]++} END {for (k in c) printf "  Exitval %-4s %d\n", k, c[k]}' "$RUN_DIR/joblog/node_${ID}.txt" 2>/dev/null \
    | sort -k2,2n
echo "  0=完了 / 124=時間切れで停止 / 3=前回時間切れのためスキップ / その他=失敗"
exit "$rc"
