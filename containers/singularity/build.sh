#!/bin/bash
# Singularity イメージ (.sif) を containers/singularity/ にビルドする。
#   ./build.sh                 # 6.0 / 7.4.1 / 8.2.0 をすべてビルド (既にある .sif はスキップ)
#   ./build.sh 7.4.1 8.2.0     # 指定したバージョンだけ
#   FORCE=1 ./build.sh 8.2.0   # 既存の .sif を作り直す
# 出力: containers/singularity/freesurfer_<ver>_parallel.sif
#
# 既定で --fakeroot を付ける (root 権限なしでマスターノードでビルドできる)。
# 付けたくない場合は SINGULARITY_BUILD_OPTS="" ./build.sh (root で実行する場合など)。
# ベースイメージ (Docker Hub の freesurfer/freesurfer:<ver>) のキャッシュは ~/.singularity/cache に溜まる。
# 不要になったら `singularity cache clean` で消せる。
set -euo pipefail
cd "$(dirname "$0")"
SIF_DIR="${SIF_DIR:-.}"
OPTS="${SINGULARITY_BUILD_OPTS---fakeroot}"
FORCE="${FORCE:-0}"
SINGULARITY_BIN="${SINGULARITY_BIN:-$(command -v singularity || command -v apptainer || echo singularity)}"

VERSIONS=("$@")
[ ${#VERSIONS[@]} -gt 0 ] || VERSIONS=(6.0 7.4.1 8.2.0)

for v in "${VERSIONS[@]}"; do
    def="freesurfer_${v}_parallel.def"
    sif="${SIF_DIR}/freesurfer_${v}_parallel.sif"
    [ -f "$def" ] || { echo "ERROR: $def not found" >&2; exit 1; }
    if [ -f "$sif" ] && [ "$FORCE" != "1" ]; then
        echo "SKIP: $sif は既にある (作り直すなら FORCE=1)"; continue
    fi
    echo "=== build $sif ($def) ==="
    force_opt=(); [ "$FORCE" = "1" ] && force_opt=(--force)
    # shellcheck disable=SC2086
    "$SINGULARITY_BIN" build $OPTS "${force_opt[@]}" "$sif" "$def"
done
