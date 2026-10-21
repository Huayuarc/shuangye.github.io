# HideNCHeaders 1.0.5 静态验证

注意：以下为交叉编译产物静态检查，不代表 iOS 16.3 真机测试通过。

- PASS: arm64: Mach-O subtype=0x00000000，初始化入口 __mod_init_func，系统库依赖，1 个 CodeDirectory / 17 个代码页签名哈希通过
- PASS: arm64e: Mach-O subtype=0x80000002，初始化入口 __init_offsets，系统库依赖，1 个 CodeDirectory / 17 个代码页签名哈希通过
- PASS: arm64e: versioned ABI 标记及指针认证指令/认证节均存在
- PASS: Fat 动态库：恰好 arm64 + 真正 versioned arm64e 两个切片
- PASS: 注入过滤：仅 com.apple.springboard，无 App 注入
- PASS: 安装元数据：已移除 firmware 的 iOS 版本上下限依赖；不代表跨系统版本实测兼容
- PASS: 元数据：隐藏通知清除按钮 1.0.5 / 作者与维护者 L.E；RootHide iphoneos-arm64e 包架构，原包 ID 可直接覆盖升级
- PASS: 最终 deb：仅 dylib + SpringBoard filter；与签名产物逐字相同；所有者 root；无安装/卸载脚本和设置页
- PASS: 组间占位修复：两个架构均包含列表头高度、组/section 数据源及独立缓存 hook；非目标标题保留原值
- PASS: 修复回归：两个切片均有新式 CoalescingHeaderCell + 旧式标题类及各自高度入口
- PASS: 底部补漏：双架构均有 ControlsCell + ControlsView 隐藏、类高度归零、footer 数据源与专属边距归零
- PASS: footer 隔离：实际 list 的非目标摘要优先，owner/list 身份匹配；不改原高度缓存 setter 或原始边距
- PASS: 视图兜底：两种标题与两种分组控制类 frame/bounds/测量高度归零，保留宽度；不对整个列表、卡片及通用按钮安装几何 hook
- PASS: 源码边界：标题和分组底部控制及其匹配占位，严格运行时签名检查，有界重试，无全局 itemSpacing/frame 改写/通知删除调用
- PASS: 本机 GNU ObjC 模拟回归：205 条断言 / 600 次复用；新增底部隐藏/占位/视图兜底、类型与归属切换、原缓存和卡片/列表几何不改（非 UIKit 真机测试）

## 文件

- deb SHA256: `594c7d41a1549c62f943a199c9c005af5d60d098a1dc40433eb189ccc79ec314`
- dylib SHA256: `cb8bd1be6efa2d788c44576dc4eda2bdfbf74de746b571e068a57708886372ba`

## 尚未验证

- iOS 16.3 真机新增底部控制行隐藏、实际标题/底部占位及与其他通知插件并用时的界面效果。
- 公开 iOS 17 头文件与本机 iOS 16.5 SDK 导出不能代替 iOS 16.3 设备运行。
- 需安装后重启桌面，在锁屏与通知中心分别展开同 App 多条通知验收。
