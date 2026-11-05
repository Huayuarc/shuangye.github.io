# SwipeDeckUnlock — 运行时免激活

不修改任何二进制、不动代码签名。做法是在目标镜像刚被 dyld 映射、
其 constructor 尚未执行的窗口里，把「是否已激活」判定函数的返回指令
就地改成恒返回 1。函数体照常执行（验签、写缓存、设全局变量都不跳过）。

## 补丁点

| 镜像 | arm64 | arm64e |
|---|---|---|
| SwipeDeck.dylib | 0x962A0 | 0x9DA1C |
| SwipeDeckPrefs  | 0xAAD18 | 0xB3BA8 |

改的是同一条指令：

```
and w0, w22, #1    (0x120002C0)   ->   mov w0, #1   (0x52800020)
```

## 编译（macOS + Theos，rootless）

```bash
export THEOS=~/theos
cd SwipeDeckUnlock
make package THEOS_PACKAGE_SCHEME=rootless
```

产物：`packages/com.zaka.swipedeckunlock_1.0.0_iphoneos-arm64.deb`

## 安装

```bash
# 手机端用 Filza / Sileo 装 packages/ 里的 deb，然后 Respring
```

## 关键开关

如果装上后想立刻停用，创建一个空文件即可（下次启动生效）：

```
/var/mobile/Library/Preferences/com.zooah.swipedeck.unlock.disabled
```

删除该文件恢复正常。

## 注意

- 注入过滤在 `SwipeDeckUnlock.plist` 里，只投 SpringBoard 和 Preferences。
- 加载顺序无法 100% 保证：如果 SwipeDeck 比本 tweak 先初始化，插件本体的
  hook 会认为未激活而跳过安装。此时 Respring 一次再看；仍不行就直接用
  二进制补丁版 deb（签名已正确重算）。
- 本工程未在沙箱里编译验证（无 iOS SDK），只做了语法与逻辑层面检查。
