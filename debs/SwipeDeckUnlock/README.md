# SwipeDeck Unlock — 运行时免激活

## 偏移表 (0.5.2-20)

| 镜像 | arm64 | arm64e |
|---|---|---|
| SwipeDeck.dylib | 0x963C8 | 0x9DB40 |
| SwipeDeckPrefs  | 0xAAD78 | 0xB3C08 |

## 安装

```bash
dpkg -i com.huayuarc.swipedeckunlock_1.0.0_iphoneos-arm64.deb
killall -9 SpringBoard
```

## 关键开关

创建空文件停用：
/var/mobile/Library/Preferences/com.zooah.swipedeck.unlock.disabled
