#!/bin/bash
# コンテナ内で被験者1人分の recon-all を実行する (GNU Parallel から呼ばれる)。
# 引数: 被験者ID (例: sub-100053248969)
# 環境変数: RECON_FLAGS, THREADS_PER_JOB, JOB_TIMEOUT, RETRY_TIMEOUT
# マウント: /input (rawdata), /output (SUBJECTS_DIR)
#
# 判定 (scripts/singularity/check_status.sh と同じ基準):
#   完了     : recon-all.done に END_TIME があり、それより新しい recon-all.error がない → スキップ
#              (FreeSurfer 6 / 8 は失敗時にも "1" だけの recon-all.done を作るので、done の有無だけでは判定しない)
#   時間切れ : recon-all.timeout がある → スキップ (RETRY_TIMEOUT=1 ならやり直す)
#   それ以外 (失敗 / 中断): 前回のログを scripts/prev_<日時>/ に退避してから -all でやり直す
#              (-all は全ステップを最初から実行する。途中のステップからの再開ではない)
#   取り込み (mri/orig/001.mgz) まで進んでいなければ、ディレクトリを消して -i から始め直す
#
# 時間切れ (JOB_TIMEOUT):
#   recon-all を開始してから JOB_TIMEOUT (例: 24h, 90m, 2d。0 で無制限) を過ぎても終わらなければ、
#   recon-all とその子プロセス (mris_fix_topology など) を SIGTERM で止める。10分以内に終わらなければ SIGKILL。
#   止めた被験者には scripts/recon-all.timeout を作り、止めた時点のステップを記録する。
#   終了コード: 124 = 時間切れで止めた / 3 = 前回時間切れのためスキップ
sub="${1:?subject id required}"
export SUBJECTS_DIR=/output
JOB_TIMEOUT="${JOB_TIMEOUT:-24h}"
RETRY_TIMEOUT="${RETRY_TIMEOUT:-0}"
sd="$SUBJECTS_DIR/$sub"
sc="$sd/scripts"

# "24h" などを秒に変換 (timeout コマンドと同じ書式: 数字 + s/m/h/d)
to_seconds() {
    local v="${1%[smhd]}" u="${1: -1}"
    case "$u" in
        m) echo $((v * 60)) ;; h) echo $((v * 3600)) ;; d) echo $((v * 86400)) ;;
        *) echo "${1%s}" ;;
    esac
}
[[ "$JOB_TIMEOUT" =~ ^[0-9]+[smhd]?$ ]] || { echo "ERROR: invalid JOB_TIMEOUT=$JOB_TIMEOUT (例: 24h)" >&2; exit 2; }
LIMIT_SEC=$(to_seconds "$JOB_TIMEOUT")

# イメージに hostname コマンドが無い場合 (7.4.1 の CentOS Stream 8 など) の代わり。
# recon-all は `hostname` の結果を IsRunning.* の HOST に書き、check_status.sh はそれで実行中かを判定する。
if ! command -v hostname >/dev/null 2>&1; then
    shim="$(mktemp -d)"; trap 'rm -rf "$shim"' EXIT
    printf '#!/bin/sh\ncat /proc/sys/kernel/hostname\n' > "$shim/hostname"; chmod +x "$shim/hostname"
    export PATH="$shim:$PATH"
fi

in=$(ls /input/"$sub"/ses-1/"$sub"_T1w.nii* 2>/dev/null | head -n1)
[ -n "$in" ] || { echo "ERROR: no T1w for $sub" >&2; exit 1; }

if [ -f "$sc/recon-all.done" ] && grep -q '^END_TIME' "$sc/recon-all.done" \
   && { [ ! -f "$sc/recon-all.error" ] || [ "$sc/recon-all.done" -nt "$sc/recon-all.error" ]; }; then
    echo "SKIP (done): $sub"; exit 0
fi

if [ -f "$sc/recon-all.timeout" ] && [ "$RETRY_TIMEOUT" != "1" ]; then
    echo "SKIP (timeout; RETRY_TIMEOUT=1 でやり直す): $sub $(head -n1 "$sc/recon-all.timeout")"; exit 3
fi

if [ -d "$sd" ] && [ ! -f "$sd/mri/orig/001.mgz" ]; then
    echo "RESTART (no orig/001.mgz): $sub"
    rm -rf "${SUBJECTS_DIR:?}/${sub:?}"
fi

if [ -d "$sd" ]; then
    # 前回の失敗・中断・時間切れの記録を退避してからやり直す
    prev="$sc/prev_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$prev"
    for f in recon-all.log recon-all-status.log recon-all.error recon-all.done recon-all.timeout "$sc"/IsRunning.*; do
        f="$(basename "$f")"
        [ -e "$sc/$f" ] && mv "$sc/$f" "$prev/"
    done
    echo "RERUN (previous logs -> ${prev#$SUBJECTS_DIR/}): $sub"
    args=(-s "$sub")
else
    args=(-s "$sub" -i "$in")
fi

start=$(date +%s)
timeout --kill-after=10m "$JOB_TIMEOUT" recon-all "${args[@]}" $RECON_FLAGS -openmp "$THREADS_PER_JOB"
rc=$?
elapsed=$(( $(date +%s) - start ))

# 124: SIGTERM で止まった / 137: SIGKILL が必要だった (メモリ不足の強制終了と区別するため経過時間も見る)
if [ "$LIMIT_SEC" -gt 0 ] && { [ $rc -eq 124 ] || [ $rc -eq 137 ]; } && [ "$elapsed" -ge "$LIMIT_SEC" ]; then
    step="$(tail -n 1 "$sc/recon-all-status.log" 2>/dev/null | sed 's/^#@# *//')"
    {
        echo "TIMEOUT after $JOB_TIMEOUT (step: ${step:-unknown})"
        echo "START_TIME $(date -d @"$start" '+%Y-%m-%d %H:%M:%S %Z')"
        echo "KILL_TIME $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "EXIT_CODE $rc"
    } > "$sc/recon-all.timeout"
    rm -f "$sc"/IsRunning.*
    echo "TIMEOUT after $JOB_TIMEOUT: $sub (step: ${step:-unknown})" >&2
    exit 124
fi
exit $rc
