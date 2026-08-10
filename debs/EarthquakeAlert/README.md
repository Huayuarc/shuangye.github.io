# 地震信息提醒（越狱 iOS）

面向 rootless 越狱 iOS 15+ 的 Theos 插件。后台轮询 USGS/EMSC 公开地震目录，并通过 SpringBoard 显示全屏提醒。

> 本项目使用的是震后公开地震目录，不是政府或厂商官方秒级 EEW。可能存在发布和轮询延迟，请勿作为唯一避险依据。

## GitHub Actions 打包

仓库包含 `.github/workflows/build-deb.yml`，在 macOS runner 上自动安装 Theos、iOS SDK 和 `ldid`，生成 rootless `.deb`。

触发方式：

- 推送到 `main` 或 `master`；
- 在 Actions 页面手动运行；
- 推送 `v*` 标签时，同时创建 GitHub Release 并附加 `.deb` 与 SHA-256 校验文件。

构建成功后，在 Actions 对应任务的 **Artifacts** 下载 `earthquake-alert-rootless-deb`。

## 本地构建

```sh
export THEOS=/path/to/theos
make clean package FINALPACKAGE=1
```

输出位于 `packages/`。

## 兼容性

- iOS 15+
- arm64 / arm64e
- rootless 越狱
- Theos + Logos

详细审查结果参见 [审查与改进说明](./审查与改进说明.md)。
