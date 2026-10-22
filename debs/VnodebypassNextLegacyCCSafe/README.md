# Vnodebypass-next 0.4.7-Next-fix5

最小范围修复：恢复用户上传 `0.4.6-Next` 的桌面 App、helper、290 项路径列表、维护脚本和旧启停语义；仅重新编译 1×1 `VBModule`。

fix3 的 CC 只有 arm64，而上传旧版为 FAT arm64+arm64e；iPhone14,2 的 SpringBoard 是 arm64e。fix4 恢复双切片后，SpringBoard IPS 证实 `VBModule +0x63cc` 因 `contentViewController` 未识别选择器进入安全模式。fix5 保留 FAT 双切片，并完全移除触摸手势对象、异步初始化和所有 `contentViewController` 调用，仅在 `setSelected:` 同步读取当前 UIEvent。

## 逐字节保留

- App `vnodebypass`: SHA256 `25f457fae040699504082b8ca4e94e5c5238affe18c3fd3147569adba942bf42`
- helper `vnodebypass`: SHA256 `7b5e74eceee07dfc94f8df766eb168a83f0a52faf12af8a48888bca97c93a4f6`
- `hidePathList.plist`: SHA256 `5b3859bf4849f290b4198283ccb5886d3e23aba48dbaca8026e12f0ceae2c07b`，290 项/276 唯一项。

桌面 App 继续按旧版流程执行 `-s`→`-h`、`-r`→`-R`；helper 的 `/var/jb` unlink/symlink、VISSHADOW、引用计数和完整列表行为均未修改，也未重编译。

## 唯一功能改动：CC

- 恢复旧版 `VBModule : CCUIToggleModule` 和原 Info.plist/图标/1×1 规格，确保 CCSupport 按旧模块模型实例化。
- 系统在添加、重载、布局或恢复状态时程序化调用 `setSelected:`：没有真实触摸凭证，立即返回，不运行 helper。
- 用户真实点击模块：沿用旧命令 `-s/-h` 或 `-xr/-R`。
- 修复旧 CC 丢弃 persona attr、旧 bundle ID 推导 helper 路径及忽略子进程退出状态的问题；helper 固定从当前 Dopamine preboot 根定位，带 `/var/jb` 兜底。
- 串行队列和 busy 门禁防止快速重复点击交错执行。

## 重要边界

恢复完整列表也恢复原风险：全局隐藏、删除 `/var/jb`、共享 vnode VISSHADOW 和直接引用计数修改可能影响其他插件，并有内核竞态/异常重启风险。这是按用户要求恢复旧模式，不是对该机制安全性的重新保证。

触摸凭证依赖 iOS/CCSupport 的实际事件顺序。本地仅完成 arm64 编译、链接、签名和静态门禁检查；仍需目标设备验证“模块显示、真实点击工作、无点击不执行”。

## 安装与验收

1. 当前 fix2 显示 `0/0 未启用` 时直接安装 fix3；若出现其他状态，先完整重启并重新越狱。
2. 安装后重启用户空间，使 SpringBoard 卸载旧 CC 二进制。
3. 设置→控制中心若已有模块，先移除再添加一次；确认主控制中心出现 1×1 图标。
4. 不点击模块，重复展开/收起控制中心、锁屏/解锁、进控制中心编辑页：桌面 App 应保持旧版“启用”状态，隐藏不得自行开启。
5. 点击模块一次：验证旧式启用；再点击一次：验证旧式关闭。随后检查其他插件。
6. 若模块仍不显示，请提供 `/var/mobile/Library/Logs/CrashReporter/SpringBoard*.ips` 或对应 JetsamEvent，以及 CCSupport 版本。
