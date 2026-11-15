# Irisin 无法解析 statoverride 账号：排查交接

日期：2026-10-28

## 要解决的问题

Apelin 安装 Command Line Tools 27.0 时，Irisin 在 preparing 阶段报错：

```text
Installation stopped: Unknown statoverride account
```

当前需要查明：设备的越狱环境能够查询到 `redis` 用户和组，为什么 Irisin 安装进程中的名称解析仍然失败？请依据实际运行环境定位，不要先假定 Redis 的记录不合法。

用户明确要求将此问题交给另一个会话处理；本会话到此停止排查。

## 已确认的证据

- 复现设备：vphone Kiwi。不要将这些观察直接套用到用户的另一台 iPhone。
- Apelin 的工具链已完成打包，失败发生在 Irisin 的安装准备阶段，不是下载或打包失败。
- 设备全局权限覆盖表 `/Library/dpkg/statoverride` 原有以下两条记录：

  ```text
  redis redis 640 /etc/redis/sentinel.conf
  redis redis 640 /etc/redis/redis.conf
  ```

- 在设备的 bootstrap shell 中，`getent passwd redis` 和 `getent group redis` 均成功；对应 UID、GID 都为 `1001`。
- 两个文件的实际 UID、GID、权限均为 `1001 1001 640`。
- 名称形式的 statoverride 记录合法。尚未追查写入者，不能断言是 Redis 安装脚本写入，更不能据此断言 Redis 写错了。
- Irisin 的实现先解析整个权限覆盖表。因此即使目标包与 Redis 无关，只要任意记录的账号解析失败，也会中止本次安装。

## 代码入口

Irisin 仓库：本地的 Irisin checkout

文件：`Packages/IrisinKit/Sources/IrisinInstaller/Database/PackageOverrides.swift`

当前本地源码中，`PackageOverrides.init(directory:)` 的关键逻辑：

```swift
func number(_ text: String) -> UInt32? {
    UInt32(text.hasPrefix("#") ? String(text.dropFirst()) : text)
}
let uid = number(parts[0]) ?? getpwnam(parts[0])?.pointee.pw_uid
let gid = number(parts[1]) ?? getgrnam(parts[1])?.pointee.gr_gid
guard let uid, let gid else {
    throw PackageFailure("Unknown statoverride account")
}
```

只要 UID 或 GID 中任意一个为 nil，就产生相同错误。现有日志不能分辨究竟是哪一次查询失败，或者两者都失败。

注意：以上为本地源码观察，尚未核实设备所装 Irisin 与此 checkout 的版本、提交和二进制是否完全对应。

## 本次失败日志

Apelin 环境任务 ID：

```text
0f9a054c-9bbf-49f2-bb21-a3d3676b0c3a
```

设备 bootstrap 内的任务日志：

```text
/var/lib/apelin/tasks/0f9a054c-9bbf-49f2-bb21-a3d3676b0c3a.events.jsonl
```

该目录需要 root 权限。路径指设备 bootstrap 视图；从系统根访问时应按实际安装根解析，不能硬编码复用。

关键事件：

```text
13:23:57Z  irisin-install external uid 0 root /private/var/containers/Bundle/Application/.jbroot-000114514191980C
13:23:59Z  ==> preparing
13:23:59Z  Database .../Library/dpkg, 1 to install, 0 to remove
13:23:59Z  [!!] Installation stopped: Unknown statoverride account
13:23:59Z  ===> irisin-install exit 1
13:24:00Z  internal: install bridge: [!!] Installation stopped: Unknown statoverride account
```

这些时间是日志中的 UTC 时间，对应北京时间 21:23–21:24。

安装事务 ID：`d7af9832-1d16-4f7f-9faa-ac6d1b8b09e1`

Apelin installation ID：`80cc46ea-15a6-454d-982d-f15f7473939b`

目标包：`wiki.qaq.apelin.toolchain.b7c9ecde91f0cca89ea0594f`

版本：`27.0+b7c9ecde`

## 已执行的设备修复及当前状态

为让用户继续安装工具链，已将上述两条记录的用户名、组名改为等价数字形式：

```text
#1001 #1001 640 /etc/redis/sentinel.conf
#1001 #1001 640 /etc/redis/redis.conf
```

原始文件备份保存在设备：

```text
/Library/dpkg/statoverride.apelin-backup-20261028-212633
```

执行前核对了账号 ID 和两个文件的实际权限，并取得 dpkg 的 `lock-frontend`、`lock` 文件锁；替换前再次核对原始内容。备份及替换保留原文件所有权和权限。

修复后已确认：

- 覆盖表实际保存的是 `#1001 #1001`。
- 两个 Redis 文件仍为 `1001 1001 640`。
- `dpkg-statoverride --list` 可正常读取；它的输出仍会将数字 ID 解析回 `redis`，不能用这一显示结果判断文件是否被改回。

这只是设备上的规避措施，不是 Irisin 的代码修复。未修改 Irisin 源码，也未替用户再次执行工具链安装；截至交接，尚无修复后完整安装成功的验证结果。

不要直接覆盖还原整个备份：设备此后可能新增权限记录。若需要复现原问题，应检查当前状态、保护后续变化，并只针对对应两条记录操作。

## 尚未查明，供后续会话验证

1. 核实设备 Irisin 版本和执行二进制，找到与实际安装版本对应的源码。
2. 在真实 `irisin-install` 执行上下文中分别观察 `getpwnam("redis")` 和 `getgrnam("redis")` 的结果；bootstrap shell 的 `getent` 成功不能证明另一进程中的 libc 查询相同。
3. 比较两个进程所使用的账号数据源、路径视图及初始化环境。系统与 bootstrap 的账号解析是否有差异，目前只是待验证的方向，不是结论。
4. 确认根因后设计正确的名称解析修复；不要把跳过所有无法解析的权限记录当作默认解法，这可能静默改变安装文件的安全属性。
5. 将错误诊断改得可定位：至少能区分未知用户、未知组及对应覆盖路径。
6. 针对名称形式、数字形式、真实不存在的账号做定向验证，并验证权限覆盖仍被正确应用。

## 工作约束

- 接手后先读取 Irisin 仓库自身的 AGENTS.md，再决定实现和验证方式。
- 不需要继续处理本会话的 Apelin UI 排版清单；用户正在逐项决策，那些建议未获批量修改授权。
- Apelin 工作区有大量尚未提交的 UI 改动，保持原样；本交接没有授权提交或推送。
- 用户不希望 UI 小改动运行全量测试；本问题涉及安装器权限处理，应按实际修复范围选择有针对性的验证。
- 不在交接文档、日志或提交中保存设备凭据。
