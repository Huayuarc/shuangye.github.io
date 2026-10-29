# SwipeDeck Unlock — 运行时免激活

不修改任何二进制、不动代码签名。做法是在目标镜像刚被 dyld 映射、
其 constructor 尚未执行的窗口里，把「是否已激活」判定函数的返回指令
就地改成恒返回 1。函数体照常执行（验签、写缓存、设全局变量都不跳过）。

## 修复

SDWriteInsn 写入指令后会恢复页面权限为 READ|EXECUTE，避免 iOS 代码签名
在执行被修改页面时触发 KERN_PROTECTION_FAILURE 导致 SpringBoard 崩溃。

## 安装

```bash
# rootless/Dopamine
dpkg -i com.huayuarc.swipedeckunlock_1.0.0_iphoneos-arm64.deb

# RootHide
dpkg -i com.huayuarc.swipedeckunlock_1.0.0_iphoneos-arm64e.deb
```

## 关键开关

创建空文件停用：

```
/var/mobile/Library/Preferences/com.zooah.swipedeck.unlock.disabled
```
