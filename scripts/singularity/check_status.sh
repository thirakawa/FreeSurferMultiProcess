#!/bin/bash
# SUBJECTS_DIR 以下の各被験者 (sub-*) の recon-all の状態を一覧にする。
#   scripts/singularity/check_status.sh <SUBJECTS_DIR>                     # 集計 + 完了以外の一覧
#   scripts/singularity/check_status.sh -a <SUBJECTS_DIR>                  # 完了も含めて全員を表示
#   scripts/singularity/check_status.sh -o <OUT_DIR> <SUBJECTS_DIR>        # 状態ごとの被験者リストを OUT_DIR に保存
#   scripts/singularity/check_status.sh -r <RAW_DIR> <SUBJECTS_DIR>        # rawdata と比べて未着手も数える
#
# 判定 (recon-all.done は FreeSurfer 8 では失敗時にも作られる ("1" だけ書かれる) ので、それだけでは判定しない)
#   done        : recon-all.done に END_TIME があり、それより新しい recon-all.error がない
#   timeout     : recon-all.timeout がある (JOB_TIMEOUT を過ぎたため recon_worker.sh が止めた。止めた時点のステップを表示)
#   failed      : recon-all.error がある (失敗したステップと原因を表示)
#   running     : IsRunning.* があり、その HOST (ノード名) で自分の Slurm ジョブが動いている
#   interrupted : IsRunning.* があるが、HOST のノードで自分の Slurm ジョブが動いていない (時間切れ・scancel 等で中断)
#   running?    : IsRunning.* があるが、実行中かどうか判断できない (HOST が空・Slurm のノードではない・squeue が使えない)
#   incomplete  : 上のどれでもない (ディレクトリだけ作られて止まった等)
#   not_started : rawdata にあるが SUBJECTS_DIR にない (-r 指定時のみ)
set -uo pipefail

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

SHOW_ALL=0; OUT_LIST_DIR=""; RAW_DIR=""
while getopts "ao:r:h" opt; do
    case $opt in
        a) SHOW_ALL=1 ;;
        o) OUT_LIST_DIR="$OPTARG" ;;
        r) RAW_DIR="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
SD="${1%/}"
[ -d "$SD" ] || { echo "ERROR: $SD not found" >&2; exit 1; }

# Slurm で実行中のノード (自分のジョブのうち RUNNING のもの)。Singularity では IsRunning の HOST がノード名になる
RUNNING_NODES=""; HAVE_SLURM=0
if command -v squeue >/dev/null 2>&1 && nl="$(squeue -h -u "$USER" -t RUNNING -o %N 2>/dev/null)"; then
    HAVE_SLURM=1
    for n in $nl; do RUNNING_NODES+="$(scontrol show hostnames "$n" 2>/dev/null)"$'\n'; done
fi

# 失敗の原因を recon-all.log から推定する
failure_reason() {
    local log="$1"
    [ -f "$log" ] || { echo "recon-all.log なし"; return; }
    if grep -aq '^Killed' "$log"; then
        echo "Killed (メモリ不足の可能性大)"
    else
        # 最後に出た "error: ..." 行。なければ中身のある最後の "ERROR: ..." 行
        local r
        r="$(grep -a '^error: ' "$log" | tail -n 1 | tr -d '\000')"
        [ -n "$r" ] || r="$(grep -a '^ERROR: *[^ ]' "$log" | tail -n 1 | tr -d '\000')"
        echo "${r:-不明}" | tr '\t' ' ' | cut -c1-100
    fi
}

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
for d in "$SD"/sub-*/; do
    [ -d "$d" ] || continue
    s="$(basename "$d")"; sc="$d/scripts"
    status=""; step="-"; reason="-"
    done_ok=0
    if [ -f "$sc/recon-all.done" ] && grep -q '^END_TIME' "$sc/recon-all.done"; then done_ok=1; fi

    if [ "$done_ok" = 1 ] && { [ ! -f "$sc/recon-all.error" ] || [ "$sc/recon-all.done" -nt "$sc/recon-all.error" ]; }; then
        status="done"
        h="$(awk '/^RUNTIME_HOURS/ {print $2}' "$sc/recon-all.done")"
        reason="${h:+${h}h}"; reason="${reason:--}"
    elif [ -f "$sc/recon-all.timeout" ]; then
        status="timeout"
        step="$(sed -n '1s/.*(step: \(.*\))$/\1/p' "$sc/recon-all.timeout" | cut -c1-40)"; step="${step:--}"
        reason="$(head -n 1 "$sc/recon-all.timeout" | sed 's/ (step: .*//')"
    elif [ -f "$sc/recon-all.error" ]; then
        status="failed"
        step="$(awk '/^CMD/ {print $2; exit}' "$sc/recon-all.error")"; step="${step:-?}"
        reason="$(failure_reason "$sc/recon-all.log")"
    elif ls "$sc"/IsRunning.* >/dev/null 2>&1; then
        host="$(awk '/^HOST/ {print $2; exit}' "$(ls "$sc"/IsRunning.* | head -n 1)")"
        step="$(tail -n 1 "$sc/recon-all-status.log" 2>/dev/null | sed 's/^#@# *//' | cut -c1-40)"; step="${step:--}"
        if [ "$HAVE_SLURM" = 1 ] && [ -n "$host" ] && sinfo -h -n "$host" -o %N 2>/dev/null | grep -qx "$host"; then
            # HOST が Slurm のノード: そのノードで自分のジョブが動いていれば running、なければ interrupted
            if grep -qx "$host" <<< "$RUNNING_NODES"; then status="running"; reason="node $host"; else status="interrupted"; reason="node $host で自分のジョブは動いていない"; fi
        else
            status="running?"; reason="host=$host"
        fi
    else
        status="incomplete"
    fi
    printf '%s\t%s\t%s\t%s\n' "$s" "$status" "$step" "$reason" >> "$TMP"
done

# rawdata と比べて未着手を追加
if [ -n "$RAW_DIR" ]; then
    for d in "${RAW_DIR%/}"/sub-*/; do
        [ -d "$d" ] || continue
        s="$(basename "$d")"
        [ -d "$SD/$s" ] || printf '%s\tnot_started\t-\t-\n' "$s" >> "$TMP"
    done
fi

# ---- 集計 ----
echo "SUBJECTS_DIR: $SD"
total=$(wc -l < "$TMP")
for st in done failed timeout running interrupted "running?" incomplete not_started; do
    n=$(awk -F'\t' -v st="$st" '$2==st' "$TMP" | wc -l)
    [ "$n" -gt 0 ] && printf '  %-12s %5d\n' "$st" "$n"
done
printf '  %-12s %5d\n' "total" "$total"

# 失敗の内訳 (ステップ × 原因)
if awk -F'\t' '$2=="failed"{f=1} END{exit !f}' "$TMP"; then
    echo; echo "失敗の内訳 (件数 / ステップ / 原因):"
    awk -F'\t' '$2=="failed" {r=$4; if (r ~ /^Killed/) r="Killed"; print $3 "\t" r}' "$TMP" \
        | sort | uniq -c | sort -rn | awk -F'\t' '{printf "  %s  %s\n", $1, $2}'
fi

# ---- 一覧 ----
echo
printf '%-20s %-12s %-28s %s\n' SUBJECT STATUS STEP DETAIL
if [ "$SHOW_ALL" = 1 ]; then cat "$TMP"; else awk -F'\t' '$2!="done"' "$TMP"; fi \
    | sort -t$'\t' -k2,2 -k1,1 | awk -F'\t' '{printf "%-20s %-12s %-28s %s\n", $1, $2, $3, $4}'

# ---- 状態ごとの被験者リストを保存 ----
if [ -n "$OUT_LIST_DIR" ]; then
    mkdir -p "$OUT_LIST_DIR"
    for st in done failed timeout running interrupted "running?" incomplete not_started; do
        f="$OUT_LIST_DIR/${st%\?}.txt"; [ "$st" = "running?" ] && f="$OUT_LIST_DIR/running_unknown.txt"
        awk -F'\t' -v st="$st" '$2==st {print $1}' "$TMP" | sort > "$f"
        [ -s "$f" ] || rm -f "$f"
    done
    { printf 'subject\tstatus\tstep\tdetail\n'; sort "$TMP"; } > "$OUT_LIST_DIR/status.tsv"
    echo; echo "リストを保存しました: $OUT_LIST_DIR (status.tsv, <状態>.txt)"
fi
