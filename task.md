# 任务描述

将 KernelSU 集成到 Pixel 4 (flame) 手机内核中，并通过 GitHub Actions 自动构建内核镜像。

## 源码信息

| 项目 | 地址 | 分支/版本 |
|------|------|-----------|
| Pixel 4 内核源码 | https://android.googlesource.com/device/google/coral-kernel | `android-10.0.0_r33` |
| KernelSU 源码 | https://github.com/tiann/KernelSU | `v0.9.5` |

> **说明：** 需将内核源码克隆到本地后，一并上传至自建 GitHub 仓库，避免后续原始仓库不可访问。

## 集成方法

参考 KernelSU 官方非 GKI 集成指南：
https://github.com/tiann/KernelSU/blob/main/website/docs/guide/how-to-integrate-for-non-gki.md

## 要求

1. 创建 GitHub 仓库，名称为 `build-flame-kernelsu`
2. 将内核源码（`android-10.0.0_r33` 分支）克隆到本地，集成 KernelSU（`v0.9.5`）后推送到该仓库
3. 按照 Non-GKI 集成指南将 KernelSU 集成到内核源码中
4. 编写 GitHub Actions 工作流，自动构建内核镜像并上传至 Releases

## 注意事项

- GitHub 密钥位于当前目录的 `.github_key` 文件中，可用于仓库创建和 Actions 操作
- **切勿将 `.github_key` 文件上传至 GitHub**
