# AGENTS.md — 本工作区怎么干活

这个仓库是用户在 GitHub Pages 上的 Cydia/Sileo 源（`https://huayuarc.github.io`），
同时充当各插件的构建入口。**它不是 Apelin 的构建描述工程，`apelin_project_build` 走
`apelin/build.sh`。**

## 两条构建路线

1. **正式发行（GitHub Actions / macOS + roothide Theos）**
   `.github/workflows/build-theos.yml` 监听 `debs/**` 的推送：对 `debs/` 下每个带
   `Makefile` 且含 `TWEAK_NAME|TOOL_NAME|APPLICATION_NAME` 的工程，依次用
   `THEOS_PACKAGE_SCHEME=rootless`（arm64）和 `roothide`（arm64e）编译打包，把
   `packages/*.deb` 提交回 `main`，然后删除 `debs/<工程>/` 源码（保留 `.gitkeep`）。
   - 所以：**源码正本放 `tweaks/<工程>/`，发布时复制到 `debs/<工程>/` 再推送。**
   - `packages/` 里的旧包会被保留，只覆盖同名产物（改过这一步，别再改成清空）。
   - 失败日志在 `build-logs` 分支的 `errors/build-run-<run_id>.txt`。
2. **本机（设备上，iOS 16 环境）**
   `apelin_project_build` 跑 `apelin/build.sh`：按 `APELIN_BOOTSTRAP` 选架构编译
   dylib、`ldid -S` 签名、拼 `DEBIAN/control`、`dpkg-deb` 出包；产物用
   `apelin_package_install` 装、`apelin_package_confirm_loaded` 确认注入
   （脚本会带 `-DAPELIN_BUILD_ID`，构造函数打印 `ApelinLoaded <id>`）。

## 本机工具链的坑

- 本机 `ld` 不接受 `-undefined dynamic_lookup`（会报 `can't exec ld64`）。dylib 里不要留
  未定义符号：substrate 的 `MSHookMessageEx` 一律用 `dlsym(RTLD_DEFAULT, ...)` 取。
- 编译器的 `/tmp` 与 bootstrap shell 的 `/tmp` 不是同一个（roothide），产物写工程内相对路径。
- 用 `clang -arch arm64e -dynamiclib -fno-objc-arc -framework Foundation` 即可。

## 现有插件

- `tweaks/CCSIMFix/`：给 `com.netskao.ccsim`（CCSIM 控制中心 SIM 开关）打的超时守卫补丁，
  解决 iOS 17 下拉/点击 CCSIM 时整机卡死。细节与自测方法见该目录 `README.md`。

## 验证习惯

- 改动后先跑 `tweaks/CCSIMFix/test/` 里的离线自测（`clang ... Tweak.m test/TestGuard.m`）。
- 装上设备后看 `apelin_log_read`（subsystem `com.huayuarc.ccsimfix`）里的
  `status installed=1`，再看控制中心里磁贴是否还在。
