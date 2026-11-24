#!/bin/bash
# Singularity イメージ(.sif)をビルドする。
# root 権限が無いクラスタでは: SINGULARITY_BUILD_OPTS="--fakeroot" ./build.sh
# 出力先は SIF_DIR で変更可能。
set -euo pipefail
cd "$(dirname "$0")"
SIF_DIR="${SIF_DIR:-.}"
OPTS="${SINGULARITY_BUILD_OPTS:-}"

singularity build $OPTS "${SIF_DIR}/freesurfer_7.4.1_parallel.sif" freesurfer_7.4.1_parallel.def
singularity build $OPTS "${SIF_DIR}/freesurfer_8.2.0_parallel.sif" freesurfer_8.2.0_parallel.def
singularity build $OPTS "${SIF_DIR}/freesurfer_6.0_parallel.sif" freesurfer_6.0_parallel.def
