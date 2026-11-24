#!/bin/bash

docker build \
    --no-cache \
    -f Dockerfile_fs_7.4.1 \
    -t freesurfer:7.4.1-parallel \
    .

docker build \
    --no-cache \
    -f Dockerfile_fs_8.2.0 \
    -t freesurfer:8.2.0-parallel \
    .

docker build \
    --no-cache \
    -f Dockerfile_fs_6.0 \
    -t freesurfer:6.0-parallel \
    .
