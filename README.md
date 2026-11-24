# FreeSurfer × GNU Parallel

OpenBHB をはじめとする T1w MRI を FreeSurfer の `recon-all` で一括処理するスクリプト群です。
実行環境ごとに、互いに独立した2種類のスクリプトがあります (スクリプトは共有しない)。

| 版 | 実行環境 | 使い方 |
|---|---|---|
| Docker 版 | 1台のサーバー。Docker コンテナ内の GNU Parallel で並列実行 | [`scripts/docker/README.md`](scripts/docker/README.md) |
| Slurm + Singularity 版 | Slurm クラスタ。被験者をノード数で分け、各ノードで GNU Parallel | [`scripts/singularity/README.md`](scripts/singularity/README.md) |

FreeSurfer のバージョンは 6.0 / 7.4.1 / 8.2.0 の3つ。

## ディレクトリ構成

```
.
├── containers/
│   ├── docker/               # Docker 版のイメージ: Dockerfile_fs_<ver> と build.sh
│   └── singularity/          # Singularity 版のイメージ: freesurfer_<ver>_parallel.def と build.sh (.sif もここに作る)
├── fs_license/license.txt    # FreeSurfer ライセンス (git 管理しないこと。両方の版で使う)
├── reports/                  # 解析結果のレポート (失敗のまとめ、公開データとの比較)。reports/README.md を参照
└── scripts/
    ├── docker/               # Docker 版: process_openbhb_<split>_<ver>.sh, recon_worker.sh, check_status.sh
    ├── singularity/          # Slurm + Singularity 版: submit_openbhb_train_<ver>.sh, submit_recon.sh,
    │                         #   recon_array_job.sh, recon_worker.sh, check_status.sh
    └── compare_openbhb_fs.py # OpenBHB 公開の FreeSurfer ROI 特徴量と自分の結果を比較する (解析用。どちらの版にも依存しない)
```

## 出力先 (`SUBJECTS_DIR`)

どちらの版も `<OUTPUT_ROOT>/<dataset>/<split>/freesurfer_<ver>/` に保存する。

| 版 | `OUTPUT_ROOT` の既定値 |
|---|---|
| Docker 版 | `/raid/hirakawa/fs_output` |
| Slurm + Singularity 版 | `/shared_datasets/BrainMRIDatasets/fs_output` |
