# FreeSurfer with GNU Parallel for Multi-Processing MRI Brain Datasets

FreeSurferで大量のMRIデータを処理するために、GNU Parallelを活用したスクリプトを作成し、処理を実行するためのプロジェクトです。

## FreeSurferとGNU Parallelの環境

`./containers/docker` ディレクトリに、FreeSurferのイメージをベースにGNU ParallelをインストールしたイメージをビルドするためのDockerfileを定義している。

FreeSurferのバージョンの観点から、6.0、7.4.1、8.2.0の3つを作成している。

## 作成して欲しいスクリプト

FreeSurferの `recon-all` とGNU Parallelを用いて、リソースの許す限り並列で同時に全てのMRIデータを処理するスクリプトを作成して欲しい。
train / valなどの適当な括りごとにスクリプトを作成して欲しい。

現在使用している端末以外のサーバーでも使用できるように、並列数や１ジョブあたりのメモリ量などのパラメータはスクリプトの変数などとして適宜修正して実行できるようにして欲しい。

### 処理したデータの保存場所

`/raid/hirakawa/fs_output` ディレクトリ以下に適宜適切なディレクトリパスを設定して保存するようにして欲しい（データセットやtrain/val、FreeSurferのバージョンなど）。

```bash
export SUBJECTS_DIR=/raid/hirakawa/fs_output/...
```

## MRIのデータセットのパスと構造

### OpenBHB Dataset

```
/raid/hirakawa/datasets/openBHB/ 
├── README.md
├── participants.tsv # meta-data relative to subjects and scans, e.g. age, sex, site label
├── qc.tsv # quality check metrics, e.g. Euler number
├── train/
    ├──derivatives/
        ├──sub-*
            ├──ses-1
                ├── sub-*_preproc-quasiraw_T1w.npy          # quasi-raw 3D volume
                ├── sub-*_preproc-cat12vbm_desc-gm_T1w.npy  # cat12 3D volume
                ├── sub-*_preproc-cat12vbm_desc-gm_ROI.npy       # gray matter volume on Neuromorphometric atlas
                ├── sub-*_preproc-freesurfer_desc-xhemi_T1w.npy  # surface-based features on mesh
                ├── sub-*_preproc-freesurfer_desc-desikan_ROI.npy # surface-based features on Desikan atlas
                ├── sub-*_preproc-freesurfer_desc-destrieux_ROI.npy # surface-based features on Destrieux atlas
        ├──cat12vbm_roi/
            cat12vbm_roi_features.csv   # GM volume on Neuromorphometric atlas concatenated across subjects
        ├──freesurfer_roi/
            desikan_roi_features.csv    # surface-based features on Desikan atlas concatenated across subjects
            destrieux_roi_features.csv  # surface-based features on Destrieux atlas concatenated across subjects
    ├──rawdata/
        ├──sub-*
            ├──ses-1
                ├── sub-*_T1w.nii # raw T1 MRI
├── val/
    ├──derivatives/
        ├──sub-*
            ...  # same structure as 'train'
    ├──rawdata/
        ├──sub-*
            ... # same structure as 'train'
├── resource/
    ├── cat12vbm_space-MNI152_desc-gm_TPM.nii.gz  # template used in CAT12 co-registration
    ├── quasiraw_space-MNI152_desc-brain_T1w.nii.gz # template used in quasi-raw co-registration
    ├── cat12vbm_labels.txt  # ROI names for Neuromorphometric atlas
    ├── freesurfer_atlas-desikan_labels.txt # ROI names for Desikan atlas
    ├── freesurfer_atlas-destrieux_labels.txt # ROI names for Destrieux atlas
    ├── freesurfer_channels.txt # Feature names derived by FreeSurfer on Destrieux/Desikan atlas
    ├── freesurfer_xhemi_channels.txt 
    ├── neuromorphometrics.csv  # Neuromorphometric labels
    ├── neuromorphometrics.nii  # Neuromorphometric atlas
    ├── resources.json  # meta-data info on numpy arrays
```
