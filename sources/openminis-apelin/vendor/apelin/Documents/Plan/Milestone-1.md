# Apelin 里程碑 1 计划

状态：owner 第三轮批注已并入（§15 末尾列出改动）。日期：2026-10-16。

**现状（2026-10-17）**：数据层已完成——A0、A1、A2、B、D1、C、F、G、H 和 I 的后端都在 main 上，由 console 无界面驱动，在 iOS 26.4 和 iOS 27.0.1 两台 roothide iPhone vphone 上实测通过（`Documents/Research/Device-Validation.md`）。E（界面）尚未开始，起点见 `Documents/Plan/Handoff.md`。下文以 **[现状]** 标出与计划不同或已完成的地方；其余文字保留为当初的计划。实际的设计决定以 `AGENTS.md` ▸ Decisions 为准。

依据：
- `AGENTS.md` ▸ Decisions ▸ Product（2026-10-16 拍板）
- 前期调研四份：工具链与 SDK、kwwk、打包安装、调试与 IDE 范围
- 设备端实测：2026-10-16 的工具链 spike（报告已删除，被下面两份取代）；`Documents/Research/2026-10-17-Toolchain-Retarget.md`（设备端改造）、`Documents/Research/Device-Validation.md`（产品链路）

标记：**[已验证]** 2026-10-16 spike 的结果，本次补文档没有复跑（之后已被产品路径的实测取代）；**[调研]** 前期调研读过源码或文档；**[设计]** 为落地补充的实现方案，尚未实现；**[待定]** 需要 owner 决定或进一步实测。已拍板的产品范围以 `AGENTS.md` 为准；下文新加的字段、路径约定和阶段安排均为设计草案。

## 目录

1. 里程碑 1 的范围和完成标准
2. 进程与 wire
3. 工具链
4. SDK 管理器
5. 开发扩展与模板
6. 代理工具扩展
7. Agent
8. 构建、打包、安装
9. 调试
10. 界面
11. 轮子清单（待审批）
12. 许可
13. 工作分解与顺序
14. 风险与待定事项
15. 审阅结论与验证记录

## 1. 里程碑 1 的范围和完成标准

里程碑 1 是一条完整的链路，在设备上从零走到"插件已加载"：

1. 设置工具链：设备从 Apple 下载 Command Line Tools，解包，改造成 iOS 可运行，注册。
2. SDK：从社区仓库下载或从文件导入，校验，注册。
3. 新建项目：从开发扩展提供的模板生成，项目自查通过。
4. 构建：编译、链接、合并切片、生成 dSYM、strip、签名。
5. 打包成 deb，经 Irisin 安装。
6. respring，确认插件已加载。

同时交付能用的 IDE 外壳：侧边栏分栏界面（iPhone、iPad）、项目管理、简单编辑器、简单终端、git、构建日志和诊断、安装、agent 面板。界面参照 FlowDown 的高性能做法（ListViewKit、Litext、MarkdownView、DisplayLink），见 §10；编辑器只做基础编辑，不做补全、提示和跳转。

**完成标准**
- 上面 6 步在 iOS 26.4 和 iOS 27.0.1 的两套 vphone 环境上都能由界面操作完成，不需要 ssh；设备连接信息保留在本地测试记录中。
- agent 能用 §7 的工具独立完成"改代码 → 构建 → 安装 → respring → 确认加载"。
- roothide 和 rootless 两种包都能构建；rootless 至少在一台设备上装过、跑过。
- C、C++、ObjC 和可选 Swift 分别通过工具链冒烟；四类开发扩展各有一个模板完成构建、安装和对应功能验证。Swift 失败不能把“v1 支持 Swift”标为完成。
- 取消、断网、空间不足、app 重连和扩展卸载不会损坏已注册环境或项目；真机与 iOS 16 最低版本兼容性分别有验证记录。
- `make check`、`make harness`、`make deb-all` 全部通过。

**已经验证过的部分** [已验证]：第 1 步的下载和解包、第 2 步的社区 SDK 下载，以及临时工具完成的编译、打包、安装与加载链路。工具链改造在 Mac 上做，签名和安装使用临时 ldid/dpkg，未验证产品的设备端改造器、签名实现或 Irisin 桥接；不等于上述六步产品验收已通过。

**[现状]** 六步都已在两台 vphone 上经产品路径完成（设备端改造、`ApelinCodeSign`、经 irisind 安装、respring、日志标记确认加载），但由 console 驱动，不是界面操作；rootless、真机、iOS 16、iPad 和 Swift 仍未验证，agent 只验证了拒绝路径。

## 2. 进程与 wire

```
Apelin.app (mobile)                     界面；只渲染，不持有长任务
  │  XPC，封闭操作
apelind (root, 按需拉起)                瘦 proxy：鉴权、转发，不链接第三方代码
  └─ apelind-session (root)             会话宿主：PTY、构建任务、agent 会话注册表
       ├─ apelin-environment (mobile)   下载、解包、工具链改造、SDK 校验
       ├─ apelin-agent (mobile)         每个 agent 会话一个进程，链接 KWWKAgent
       ├─ apelin-build (mobile)         一次构建一个进程：调用工具链、签名、打包
       ├─ PTY shell (mobile)            用户终端；M1 不提供 root shell
       ├─ apelin-diagnostics (mobile)   日志/UI 适配；受保护读取见 §9
       ├─ apelin-log-reader (root)      按需日志读取；只用系统库，见 §9
       └─ 代理工具扩展进程 (mobile)       见 §6
```

- 分层照 iGhostVT 的 `ighostvtd` / `ighostvtd-io`。[调研]
- 构建、环境准备和 agent 以 mobile 身份运行；安装、respring 兜底、受保护文件访问走封闭操作。proxy、会话宿主与 root 日志 helper 都只用系统库，归档、icli 等第三方依赖放在 mobile 工作进程里。子进程避开 proxy 的 launchd 内存配置，不等于免受系统内存压力和 jetsam，必须实测。
- **生命周期（owner 2026-10-16 决定）**：apelind 按需拉起，不用 `KeepAlive` / `RunAtLoad`。有工作就不退出：任一构建、环境任务、PTY、agent 会话、安装事务或已连接的 app 存在时，proxy 和会话宿主都保持运行；全部结束且没有连接后空闲一段时间再退出。app 被杀不算没有工作，agent 和构建照常跑完。宿主退出前把任务记录落盘，下次被拉起时恢复可重做的阶段；系统重启后不主动拉起，等 app 下次连接时恢复。A0 把现有 launchd plist 从 `KeepAlive` + `RunAtLoad` 改回按需，并验证"有工作不退、空闲才退"在两套 vphone 上成立。
- 每加一个操作，就同时改 `Shared/Protocol/AppProtocol.swift`、daemon 的 switch 和 `AGENTS.md` ▸ Decisions 的列表。

**里程碑 1 要加的操作**（都是数据，没有一个是 `exec(path, argv)`）

| 组 | 操作 |
|---|---|
| 已有 | `hello` |
| 工具链 | `toolchainStatus`、`toolchainSetup{source, components}`、`toolchainRemove{id}` |
| SDK | `sdkList`、`sdkImport{url \| fd}`、`sdkRemove{id}` |
| 环境任务 | `environmentAttach{id, afterSeq}`、`environmentCancel{id}` |
| 扩展与项目 | `extensionList`、`projectCreate{templateID, values}`、`projectCheck{projectID}` |
| 构建 | `buildStart{project, configuration}`、`buildAttach{id, afterSeq}`、`buildCancel{id}` |
| 安装 | `installPackage{artifactID, digest}`、`removePackage{installationID}`（§8 的受管项目包）、`respring` |
| 文件 | `fileRead{scopeID, relativePath}` → fd；仅 app 手动编辑入口可用 `protectedEditOpen{grantID}` / `protectedEditCommit{grantID, fd, expectedVersion}` |
| 终端 | `ptyOpen`、`ptyAttach`、`ptyResize`、`ptyClose` |
| 日志与崩溃 | `logStream{filter}`、`crashList`、`crashOpen{id}` → fd |
| 诊断与 UI | `confirmLoaded{buildID, targetID}`、`captureScreen{targetID}`、`readUITree{targetID}`、`uiAction{targetID, action}`；权限按 §7/§9；能用 `owngoal-dev/icli` 实现的一律用 icli（dogfooding），见 §9 |
| agent | `agentOpen`、`agentPrompt`、`agentSteer`、`agentAbort`、`agentApprove`、`agentAttach`、`agentList`、`agentClose` |
| 代理工具扩展 | `toolHostOpen{id}`、`toolHostClose{sessionID}` |

**[现状]** 实际的封闭操作列表比上表多（`approvalDigestState`、`confirmLoadedAttach`、`crashSymbolicate`、`agentRunCode`、`agentCredentialImport`、`toolHostCall`、git 等），以 `AGENTS.md` ▸ Decisions ▸ The wire 为准。

**[设计] 连接边界**：保持 `AGENTS.md` 的“No CLI”：只有 app 是 apelind 的公共 XPC peer。`apelin-agent`、`apelin-build`、`apelin-environment` 和诊断/扩展工作进程仅通过宿主创建并继承的 socketpair/管道通信，不加入 `clientPaths`，不为接入 root proxy 配发客户端 entitlement。宿主按它启动时登记的角色和会话识别调用方，忽略请求中自报的角色；子进程关闭无关继承 fd。

**[设计] 会话和权限边界**：以上是 app 控制面的拟新增操作，当前代码仍只有 `hello`；agent 的同类任务请求通过内部通道交给宿主。A0 定义版本协商、任务 ID、事件序号、重连重放与取消协议，功能实现时同步协议、分发和 `AGENTS.md`。宿主独立执行 §7 的审批判断，不依赖 agent 自称“已批准”。app 断开不结束任务；宿主或系统重启后恢复任务记录和可重做阶段。无特权后端时按 `AGENTS.md` 保持 Connecting… 的宽限期，并提供自身权限范围内的项目编辑。

**文件范围与角色 [设计]**

| 范围 | 读取 | 写入 |
|---|---|---|
| 项目根，固定为 `~/Documents/wiki.qaq.apelin/Projects/<name>/` | app、agent、build 按 mobile 权限访问；宿主绑定项目 ID | 项目编辑与构建以 mobile 完成，不经 root 代开写 fd |
| 已注册 SDK/工具链、已安装扩展根 | 按 ID 解析的只读 scope | 仅环境导入或安装事务写入，普通文件操作不接受该范围 |
| 系统崩溃目录与日志 | 宿主枚举出 report ID/受限日志流，再交只读 fd 或数据 | 无文件写接口 |
| bootstrap 安装根内、mobile 无权写的普通文件 | app 发起的受保护编辑；mobile 已可读写的文件直接按自身权限处理 | 只允许 app 的手动编辑流程：只改已有文件的内容，单文件单次授权；agent/build/environment/扩展均不可调用 |

**项目位置（owner 2026-10-16 决定）**：项目根写死在 `~/Documents/wiki.qaq.apelin/Projects/<name>/`，不支持登记任意目录。`<name>` 即项目名：单个路径组件，拒绝 `/`、NUL、`.`、`..` 和以 `.` 开头的名字，同名已存在时创建失败。项目 ID 存在 `apelin-project.json` 里，改名只是移动目录，不改 ID。`Projects` 由 app 以 mobile 身份创建；宿主判断"是否在项目内"时，先 realpath 再按组件比较是否落在 `Projects/<name>/` 下。

受保护编辑只复用 Fila 的 `AtomicSave` 机制，`openPath` / `replaceItem` 按本计划的 scope/grant 模型重写。app 的手动选取产生限定文件的读取授权；用户在编辑器里点保存即为确认，由宿主生成绑定文件身份、版本和拟写内容的短期写入 `grantID`，提交复核并消费授权。普通配置文件须通过格式、路径、文件身份与链接检查；agent 无权创建或消费这类手动授权。路径核对遵循 `AGENTS.md`，新文件使用验证后的父目录 fd；`fileRead` 同样由宿主解析 scope。

**编辑范围（owner 2026-10-16 委托决定）**：原则是不打扰手动编辑，但任何出错都不能变成删文件或越界写。
- 范围是 `hello` 给出的 bootstrap 安装根内的普通文件，`LaunchDaemons`、`Library/Preferences` 都在内。安装根外的 `/var` 区域只读；系统卷是只读的签名卷，本来就写不了，也不提供入口。
- 只有“替换已有文件内容”一种写法：不新建、不删除、不改名、不改所有者和权限位；保存后保留原文件的 uid/gid/mode。接口里没有删除操作，出错的最坏结果是一次可撤销的内容替换。
- 每次替换前，宿主把原内容备份到 `~/Documents/wiki.qaq.apelin/backups/`（按时间和规范化路径命名，保留最近若干份），编辑器提供“恢复上一版”。
- 拒绝 Mach-O、脚本可执行文件（任一执行位）、硬链接数大于 1 的文件、符号链接，以及 dpkg 状态数据库等包管理器自己的记录。
- 点保存就是确认，不再弹窗；唯一的额外确认是 `LaunchDaemons` 下的 plist（改的是 root 下次启动执行什么），卡片显示 diff，且只保存，不自动加载或重启服务。
- Relaxed/Confirm 不影响这里；agent 没有这个接口，所以模型出错既不能借用也不能绕过它。

**PTY [设计]**：宿主创建终端后，在 exec shell 前切换为 mobile 的 UID/GID、补充组、HOME 与工作目录，并关闭特权 fd。M1 无 root-shell 选项；交互式终端在 mobile 权限内执行用户输入，agent 执行命令必须经过 §7 的工具入口。验收核对 shell 身份和 fd，不能从“宿主是 root”继承默认身份。


## 3. 工具链

**产品边界**：设备直接获取 Apple Command Line Tools（CLT），在设备上解包、改造、签名和安装；不要求 Mac、完整 Xcode 或 Apple ID。Apelin 不托管 Apple 二进制，不自编 LLVM。Swift 在 v1，设置时可选，模板默认 ObjC。改造后工具链的导入、导出属于二阶段，不与 v1 的 SDK 文件导入混为一谈。

### 3.1 来源与首次安装

- **[已验证]** 既有报告记录 CLT 27.0 的 `CLTools_Executables.pkg` 可从 Apple 软件更新目录找到并免登录下载；这是该版本的实测，不保证以后每个版本都有同样入口。
- **[设计]** 来源适配器读取 Apple catalog，列出产品 ID、版本、下载大小和包来源；只对已有适配方案的版本显示“可设置”。记录原始 URL、catalog 产品标识、上游校验信息及本地 SHA256。上游校验与本地哈希分开记录，本地哈希只用于一致性检查，不能单独证明发行者身份。
- **[设计]** 支持下载重试和断点续传；服务器对象变化时重新下载。找不到可用包或遇到未知格式时显示具体原因，保留已安装版本，不静默改用社区工具链镜像。
- **[设计]** 首次安装由主包自带的 `apelin-environment` 完成归档读取和 Mach-O 处理，不能先依赖尚未能运行的 CLT 中的 `vtool`、`install_name_tool`、git 或 Swift。helper 随 Apelin 的正常构建产生；归档库复用方案走 §11 的依赖审阅。

### 3.2 组件和兼容性

| 组件 | v1 用途 | 注册前检查 |
|---|---|---|
| C/C++/ObjC 基础工具 | clang、链接器、lipo、dsymutil、strip 及其资源和库 | 每种语言编译、链接；dSYM 与产物 UUID 对应 |
| Swift（可选） | swiftc、编译器依赖、模块资源与必要兼容 shim | 编译并运行可执行文件、动态库及异步/标准库用例 |
| 辅助工具 | 符号和二进制检查等实际需要的工具 | 依赖闭包完整；包装器调用的真实工具也存在 |

clangd 不进 v1（owner 2026-10-16 决定），闭包不包含它，见 §10。

**安装完成时自检（owner 2026-10-16 决定）**：工具链装好后自动跑一次自检，按上表逐个组件运行“注册前检查”，结果逐项显示在设置页，任一 C 系检查失败就不注册。设置页也可以手动重跑；项目自查（§5.4）发现工具链缺文件时提示重跑。

**[设计]** 按入口计算依赖闭包，保留相对布局、clang resource directory、头文件和库，不按固定文件数复制。报告中的 65 个原始镜像依赖闭包、69 个改造产物、56MB/167MB 压缩包是不同统计口径，均不作为产品常量。`otool` 缺 `llvm-otool` 的实测问题要纳入闭包验收。CLT 中出现 git 不代表已完成可用性及许可检查，SDK 下载所用 git 后端见 §4。

**兼容性按组合记录**：CLT 产品版本 + 改造器版本 + 设备系统/架构 + bootstrap 类型 + SDK 身份。编译器自身运行的架构、它能生成的目标架构、目标设备实际接受的 ABI 分开记录。arm64、arm64e、arm64e.x1 分别做编译/链接/运行检查；不能从一个切片链接成功推导 rootless 安装或其他架构运行成功。应用支持 iOS 16 不代表任意新版 CLT 都能在 iOS 16 上运行，最低版本工具链组合在 B 阶段确认。

### 3.3 解包与改造流水线 [设计]

1. **预检**：确认后端能力、来源版本和空间预算。峰值按各阶段同时存活的文件计算：下载包 + 展开内容 + 改造副本 + 临时 deb + Irisin 解包暂存/新安装目录 + 旧版本与回滚副本 + 余量。尤其计入“本地打包后再次解包”的额外副本；报告中的 816MB 依赖闭包不能代替总预算。B 实测各阶段峰值后再定空间门槛。
2. **隔离解包**：在任务自己的 staging 目录处理 xar → pbzx → cpio。先验证复用的 libarchive 能覆盖哪些层；缺失层再写最小适配器，不能把“库支持归档”当成已支持 pbzx。限制展开大小、条目数和递归层数，拒绝路径逃逸、特殊设备文件和越界链接。
3. **识别**：读取 Mach-O 各切片、加载命令、依赖与资源。验证字段范围与文件边界，解析不支持的布局就停止；遇到 AppKit 等没有对应运行环境的依赖时报告不兼容。
4. **平台与路径改写**：复用并扩展 Irisin 的 Mach-O 模块，处理平台声明、框架的 macOS 版本目录布局、库引用及所需 rpath。输出独立副本；加载命令空间不足时明确失败，未经验证不移动整个镜像布局。不添加 libvroot，运行时用 daemon 返回的物理安装根解析路径。
5. **Swift 兼容**：按版本核对未满足的符号与 ABI，只对已知组合提供 shim，记录实现来源和许可。前期调研发现 7 个缺失符号不意味着所有版本都固定缺这 7 个；单纯让符号存在也不能证明语义正确。shim 随 Apelin 构建提供，不能要求设备先有可用 swiftc 来生成它。
6. **签名与本地包**：所有字节改写完成后，用 Irisin 签名模块签名；生成仅保留在本机的工具链 deb，交 Irisin 安装。设备端安装流程也不调用 apt/dpkg。签名完成后不再改写二进制。
7. **自检与注册**：即 §3.2 的安装完成自检，对安装后的字节运行检查，验证重签、加载和资源定位。C 组件通过才注册基础工具链；Swift 单独记录通过或失败，失败时保留可用的 C 环境但明确 Swift 尚不可用。成功后原子更新注册记录。

路径与新文件落点遵循 `AGENTS.md` 和 §2 的 scope 规则。解包和改造以 mobile 运行，安装阶段由 Irisin 接收已核对的产物。

### 3.4 存放、升级与恢复 [设计]

- 下载缓存、staging、日志、注册元数据放在 `~/Documents/wiki.qaq.apelin/` 下；可执行工具链的最终安装目录约定为 `<install-root>/usr/lib/apelin/toolchains/<id>/`。采用包管理的 root-owned 目录，以便安装适配、签名和卸载归同一事务管理；mobile 可写的 `var` 数据目录只作暂存，不作为最终工具来源。该布局在 roothide 真机上的安装后重签与执行仍须 B 验证。`install-root` 来自 `hello`。
- 工具链 ID 由来源摘要与改造方案版本生成；注册记录保存组件、包标识、版本、内容摘要、冒烟结果和最终路径。项目绑定该 ID，不随“默认工具链”升级而偷偷切换。
- 新版本使用独立 ID 和可共存的本地包标识/目录，验证后再切换默认值。旧版本仍被项目或运行中任务引用时，不直接删除；界面列出引用者并要求先迁移或结束任务。卸载经 Irisin，更新注册表，不能只删目录而留下包记录。
- 设置任务记录 `downloading → extracting → adapting → packaging → installing → validating → ready` 及失败阶段。app 被杀后可重新附着；进程中断后只恢复可验证的阶段。安装中的取消由 Irisin 的事务语义处理，不能强杀到一半再标成已撤销；不支持事务取消时等待安装结束再处理清理。
- 失败和取消只清理本任务 staging，不删除旧的可用环境。首次启动核对注册表与实际安装状态，处理“已安装但尚未注册”的中断；保留可导出的诊断摘要，默认去掉凭证、设备标识和本地绝对路径。

### 3.5 验收与尚未验证的部分

**[已验证]** Apple 下载、设备解包、Mac 上改造后工具链的 C/ObjC 编译安装链路。**未验证**：设备端改造器、Irisin 产品安装链路、Swift 运行、第二套 vphone、rootless 真机、iOS 16、内存峰值。

**[现状]** 设备端改造器、经 irisind 的安装、六项 C/C++/ObjC 自检和注册已在两台 vphone 上通过（`t1-toolchain-setup.json`，25–37 秒），宿主重启后的恢复也通过。Swift 组件仍明确拒绝；rootless、真机、iOS 16 和内存压力仍未验证。

B 阶段必须从干净环境通过界面完成下载到注册；覆盖取消、断网、空间不足、坏包、未知 CLT、升级失败回退和重连。Swift 用例包含普通程序、Codable/JSON、async/await、动态库及 C 加载器；核查 CLT 缺少的 iPhoneOS Swift 兼容库是否影响目标部署版本，缺失时不能从别处静默复制 Apple 文件。设备实际运行通过才在兼容性表中标记支持。`xcodebuild` 不进入 v1 工具链，`.xcodeproj` 可浏览编辑，但本计划的构建后端不执行 Xcode 工程。

## 4. SDK 管理器

**来源**
- 社区仓库下载 [已验证]：`xybp888/iOS-SDKs` 把每个 SDK 存成仓库里的一个目录，用 `git clone --filter=blob:none --no-checkout --depth 1` 加 sparse checkout 只取一个目录。iPhoneOS 27.0 取下来 25 秒、381MB，带 PrivateFrameworks。
- **自维护仓库（owner 2026-10-16 决定）**：把 `xybp888/iOS-SDKs` fork 到 `owngoal-dev/iOS-SDKs`，再脱离 fork 关系（detach），此后由我们维护，作为 app 的默认来源。仓库 README、app 的 SDK 页和 Licenses 页致谢 xybp888 的原仓库。fork 和 detach 是单独的一步，在 A2 做，不随本计划提交。
- **[设计，待验证] 仓库布局**：既然仓库归我们维护，就按 libgit2 能高效获取的方式排布：每个 SDK 一个分支或 tag（如 `sdk/iPhoneOS27.0`），只含该 SDK 一个目录，配一份清单记录 `CanonicalName`、`Version`、内容摘要和来源。设备用浅克隆（depth 1）只取一个分支，不依赖 libgit2 不支持的 partial clone（`--filter=blob:none`）。B 用真实 SDK 测下载量、耗时和断点恢复。
- 文件导入：Files、AirDrop 传来的 zip、tar.xz、tar.zst。
- 设置里可以加其他社区来源；默认来源只有 `owngoal-dev/iOS-SDKs`。
- **[现状，owner 2026-10-19]** 已建立 `owngoal-dev/iOS-SDKs`，按 SDK 实际身份每版一个独立分支，致谢上游，默认启用；只提供完整的 14.5+ SDK，13.0–14.4 因缺 C++ 标准库头文件已排除。工具链安装缺少兼容 SDK 时自动下载最新可用版本。SDK 的权利仍属 Apple，建仓决定不表示获得额外许可。

**存放 [设计]**：`~/Documents/wiki.qaq.apelin/SDKs/<CanonicalName>-<sha8>/`。SDK 作为编译输入处理，不执行或 dlopen 其中的内容。v1 拒绝含 `MH_EXECUTE` 的文件（含 fat 镜像各切片及归档内成员）；允许作为链接输入的 `MH_DYLIB`、`MH_OBJECT` 和静态 `.a`，校验格式、架构与路径后登记。`MH_BUNDLE` 及其他未支持类型拒绝并解释原因；不用 Unix 可执行权限位代替 Mach-O 类型判断。真实 dylib 不被复制为工具链运行库，也不因 SDK 注册获得运行信任。

**识别和校验**
- 身份一律从 `SDKSettings.json` 读（`CanonicalName`、`Version`），不看目录名。[调研] Theos 的 `iPhoneOS16.5.sdk` 实际是 16.4。
- 读 `Foundation.tbd` 的 `targets`。[已验证] 社区 27.0 SDK 只有 `arm64e-ios, arm64e.x1-ios`，但设备上的 ld 仍能链出 arm64 切片，所以缺 arm64 只记一条提示，不拒绝。
- 读 Swift 模块的 `swift-compiler-version`，和已注册工具链的 Swift 版本比对；SDK 比编译器新就提示不能编 Swift。
- 每个路径先 realpath，必须留在 SDK 根目录以内，符号链接逃逸就拒绝。

**项目绑定**：每个项目固定一个 SDK（CanonicalName + sha），换 SDK 是一次显式操作。

**依赖**：B 阶段就必须交付 SDK 获取所需的 git 后端，不能等 I 阶段的 git 界面。**后端定为 libgit2（owner 2026-10-16 决定）**：在 `Lakr233/` 下新建并维护 `libgit2.xcframework`，做法照 `Lakr233/libarchive.xcframework`——Swift package，一个静态 xcframework，依赖（TLS、SSH、zlib 等）编进去，许可通知随包。A2 建仓并出第一个版本。不用 CLT 里的 git，不自行实现 Git 协议。libgit2 不支持 partial clone，所以取 SDK 靠上面的“一 SDK 一分支”布局加浅克隆，需用真实 SDK 做下载量、空间和恢复验证。源码固定到 commit 和子目录，再计算内容摘要，不能只记可移动的分支名。若必须改用归档下载，要先验证仓库大小和解包预算。

**事务与能力 [设计]**：导入在 staging 中完成，校验后原子注册；解析格式、展开限制和路径规则与 §3 一致。`Foundation.tbd` 只作初筛，每个项目目标通过实际编译/链接探针确认能力。Swift 版本提示不能替代编译探针。移除前检查项目引用；环境自查能区分文件不完整、SDK 与工具链不匹配、架构未验证。


## 5. 开发扩展与模板

**已经拍板**：IDE 主包不依赖注入框架。开发支持拆成独立扩展，主包以 `Recommends` 推荐；具体是否自动安装由用户的包管理器设置决定。未装或卸载某个扩展不影响其他项目和 IDE 启动。tweak 扩展依赖注入框架；模板来自乌龙工作室现有开源仓库，按文件约定发现。

### 5.1 四类开发扩展 [设计]

以下包名为拟定约定，实际发布前检查包源是否占用；应用标识仍以项目现有配置为准。

| 扩展 | 拟定包 ID | 模板与产物 | 验收 |
|---|---|---|---|
| 应用开发 | `wiki.qaq.apelin.dev.app` | UIKit/ObjC 应用；Swift 在对应工具链可用时提供；产物 `.app` + deb | 安装后注册、启动、显示模板界面，升级与卸载正常 |
| 插件开发 | `wiki.qaq.apelin.dev.tweak` | ObjC dylib、目标过滤文件、包元数据；默认不要求 Logos | 编译、安装、respring，日志与实际效果确认加载 |
| 命令行工具开发 | `wiki.qaq.apelin.dev.cli` | C/ObjC 命令行程序，可选 Swift；产物可执行文件 + deb | 安装后从终端运行，输出和退出码正确 |
| 设置面板开发 | `wiki.qaq.apelin.dev.preferences` | preference bundle、资源和注册文件 | 安装后设置中可见，修改与重新读取配置正常 |

tweak 包的注入框架依赖按 bootstrap 中实际支持的虚拟包/包名声明，不在 IDE 中硬编码某个实现。设置面板模板如果使用额外的面板加载器，依赖写在该扩展与生成包中，不能从主包隐式取得。App、CLI 不因为缺少注入框架而被禁用。代理工具扩展是 §6 的第五类能力，不混入这四类构建模板。

**hook 开发接口 [设计]**：tweak 扩展自带经许可审阅的 hook API 头文件及对应链接 stub（`.tbd`），不假定 iPhoneOS SDK 包含 substrate 系接口。清单记录来源/版本、导出符号、支持架构及其对应的运行时虚拟包；编译加入扩展的 include/library 路径，生成包声明同一套运行时依赖。模板调用的 API 必须属于声明的兼容集合，D2 用真实 hook 用例验证，不能只用不调用 hook API 的 Hello 弹窗代替。Logos 预处理器仍属额外可选能力。

### 5.2 安装布局与发现 [设计]

扩展数据目录约定为 `<install-root>/usr/share/apelin/development/<extension-id>/`，包含 `manifest.json`、`templates/<template-id>/` 和许可文件。主包只读取声明和模板，不把扩展动态库加载进 app。模板所需额外工具按 §6 的进程边界接入；不自动执行 manifest 中任意路径的程序。

app 启动、从安装界面返回和手动刷新时重新扫描，通过 daemon 解析安装根；每份清单单独验证。坏清单、未知 schema、重复 ID、路径越界或不兼容版本仅隔离该扩展并在设置页解释原因，不能导致整个模板列表消失。重名不采取“最后发现的覆盖前一个”。离线启动直接读取已安装文件，不依赖每次访问模板仓库。

| 清单字段 | 含义及约束 |
|---|---|
| `schemaVersion`、`id`、`version`、`kind` | 协议版本、稳定 ID、扩展版本、四种开发类型之一 |
| `displayName`、`summary` | 可显示的名称与用途，按应用本地化规则处理 |
| `apelinCompatibility` | 最低可用应用/构建描述版本，未知新版本明确提示 |
| `requirements` | 工具链组件、语言、SDK 能力、支持的 bootstrap/架构、运行依赖 |
| `templates` | 模板 ID、相对目录、参数说明和构建描述位置 |
| `provenance`、`licenses` | 源仓库、固定 commit、内容摘要和包内许可文件相对路径 |

扫描所得只是能力清单，能否创建和构建还要结合当前环境检查。缺依赖时模板可见并显示原因；IDE 不在扫描阶段自动安装包。

### 5.3 模板获取与生成 [设计]

- 构建扩展包时从已审阅的乌龙模板仓库固定 commit 导入，保留许可和必要文件头。仓库 URL、commit、模板目录及适配改动在 D 阶段登记；当前仓库尚无四类模板的完整来源清单，不能把名称相似的模板视为已经选定。
- 模板包包含创建项目所需的文件，创建时不联网。模板升级只影响之后的新项目，已有项目不被覆盖；保留来源 ID、版本与摘要，后续迁移单独设计。
- 参数至少包含项目名称、bundle/package ID、语言、部署目标、目标架构和 bootstrap。插件增加目标 bundle/process 过滤参数。按字段类型校验并按文件格式转义，不把用户输入拼成 shell 源码。
- 目标目录就是 `~/Documents/wiki.qaq.apelin/Projects/<name>/`（§2），必须不存在；先在同一文件系统的临时目录生成，通过检查后原子落盘。拒绝绝对模板路径、`..` 逃逸、越界符号链接和冲突文件；创建失败只删除本次临时目录。
- 不执行模板附带的 `postCreate` 脚本。模板可以携带作为项目产物的 maintainer 脚本，但安装前展示其内容和能力，不能用“模板可信”跳过 §7 的审批规则。

### 5.4 项目契约与自查 [设计]

每个项目使用版本化的 `apelin-project.json` 作为构建入口，至少记录：项目 ID、类型、模板来源；绑定的工具链/SDK ID 与摘要；源文件、资源与头文件目录；语言、部署目标、架构；Debug/Release 配置；链接库、framework；包 ID、依赖、安装布局及插件过滤条件。界面与 agent 读取同一份描述，不各自维护隐藏配置。v1 先使用类型化构建步骤，不把任意 shell 字符串作为默认构建模型；显式脚本走 `run_code` 和对应审批。

`projectCheck` 返回结构化诊断（代码、严重度、字段/文件位置、可用修复动作），创建后、构建前和更换环境后运行。至少检查：

1. 项目格式、参数与所有输入路径合法；输出目录不覆盖源码。
2. 工具链和 SDK 已注册且存在，语言组件齐全；部署版本、目标架构和链接能力满足项目要求。
3. 开发扩展及必要工具可用；卸载扩展后已有源码仍能编辑，依赖该扩展的构建明确提示缺项，不让整个 app 报错退出。
4. 包依赖、目标过滤和资源有效；包内逻辑路径交给 packager 根据 bootstrap 映射，项目不存具体设备的 jbroot 路径。
5. 可用空间、可写工作目录、产物签名方案与当前安装能力满足要求；缺 Irisin 时可以编辑和构建，安装步骤显示需要的服务版本。

构建保存构建日志、产物摘要、dSYM UUID、工具链/SDK 身份及模板来源。发布包及诊断导出按仓库规则清除本机绝对路径。

### 5.5 验收

干净安装主包时能正常启动；四个扩展分别安装、发现、新建、构建、安装、升级与卸载。逐一覆盖扩展缺失、注入框架缺失、坏清单、重复 ID、模板路径逃逸、无 Swift 组件和项目引用旧扩展。roothide/rootless 分别核对包布局；App、CLI、设置面板不能用“Hello tweak 成功”代替验收。验收前仍按 §11 审阅复用组件与模板来源。

## 6. 代理工具扩展

agent 能调用的工具，除了 §7 的内置本地工具，其余都做成"代理工具扩展"，和应用、插件、命令行工具、设置面板这几类开发扩展并列。

**为什么单独分发**：有些工具的许可是 GPL 系。Apelin 本体和开源仓库保持 MIT，不能把 GPL 代码链接进主包。所以：
- 每个代理工具扩展是独立的包，各自带自己的许可和源码履约材料。独立进程是工程边界，不能仅据此认定 GPL 的影响必定止于该包，见 §12。
- 扩展在**独立进程**里运行，和 Apelin 之间只有一条数据协议，不共享地址空间，不链接对方的库。
- 主包不依赖任何扩展，也不 `Recommends` GPL 的扩展；用户主动从包源安装。

**分发（owner 2026-10-16 决定）**：我们的所有包——IDE 主包、四类开发扩展、代理工具扩展——每个都出 rootless 和 roothide 两个 deb，全部放进我们的仓库索引（owngoal-packages），用户用自己的包管理器从同一个源安装。app 的扩展页只列出已装和缺失的扩展并说明用途，不自己下载安装包。CI 按 `ci.yml` / `release.yml` 构建、校验和发布，每个扩展包用自己的包 ID 和版本。

**协议**（草案）
- 扩展随包带一个清单 `<prefix>/usr/share/apelin/agent-tools/<id>/manifest.json`：id、名称、版本、许可、可执行文件的固定路径、提供的工具列表。
- 每个工具有名称、描述、JSON Schema 参数，格式与 `AgentTool` 一致，Apelin 直接转成 agent 的工具定义。
- 启动方式：apelin-agent 经继承的内部通道向宿主请求 `toolHostOpen{id}`，宿主检查登记信息和审批后拉起扩展进程；公共 XPC 入口只供 app 使用。清单和可执行文件需满足 §2 的路径和权限规则，项目中的清单不作为可执行程序登记来源。
- **[设计]** stdin/stdout 用 JSON 行交换带 `protocolVersion`、`requestID` 的 `hello`、`call{tool, args}`、`result{content}`、`error` 和 `cancel`；stderr 单独记日志。限制帧大小和并发数，规定超时、取消、崩溃及协议不兼容的错误结果；一个扩展退出不结束 agent 会话。图片通过有大小限制的附件句柄传递，不把任意大 base64 塞进事件日志。
- 扩展以 mobile 身份运行，不拿 root。文件通过宿主启动时继承的描述符或专用 socket 传递，JSON 里的附件 ID 映射到接收进程自己的 fd；不能把发送进程的 fd 整数当成可跨进程使用的句柄。传 fd 也不等于给进程提供了文件系统沙盒，不承诺可安全运行任意恶意扩展。
- 每个工具声明风险等级（只读、写项目、系统），由宿主结合实际能力归类；扩展不能靠自称只读绕过审批。来源不明的工具按需要确认处理。

**第一个扩展：反汇编**
- 内容：Capstone（反汇编）和 Keystone（汇编）；两者之前在其他项目里已经集成过，直接搬过来。
- 工具：`disassemble{binary, address, count}`、`assemble{arch, source}`、`symbols{binary}`。
- 发布：rootless、roothide 两个 deb 都放进仓库索引，和其他包一样。
- 许可：Capstone 本身为 BSD；Keystone 上游提供 GPLv2 与商业授权两种选择。若采用 GPLv2 版本，含 Keystone 的扩展按经审阅的 GPL 方案单独发布并提供对应源码，保留 Capstone 的原始许可；不把两者都标成 GPL 上游。[Capstone](https://www.capstone-engine.org/download.html)、[Keystone](https://github.com/keystone-engine/keystone)。
- 二进制解析复用 Fila 的 `MachOImage` 和 Xrash 的 `MachOSlice`，这部分是 MIT，放在扩展之外也可以。

**待定**
- 扩展是否允许带自己的界面（比如一个反汇编视图）：建议里程碑 1 只做工具，不做界面。
- 第三方能不能发布扩展：协议公开，第三方用自己的源发布；里程碑 1 不做商店或签名校验。

## 7. Agent

**形态**：方案 C。`apelin-agent` 由会话宿主拉起，以 mobile 运行，链接 KWWKAgent 和 KWWKMCP，每个会话一个进程。app 被杀、respring、挂起都不会中断它。[调研]

**模型与凭证**
- Anthropic 原生接口，加 OpenAI 兼容接口。
- 凭证存钥匙串：本机，不同步，Apelin 自己的条目。**[设计，待实测]** 首选 app 与 agent 共用专属 keychain access group；A 阶段验证两个进程在支持的 bootstrap 上的读写和锁屏行为。若不可行，由 app 通过已鉴权连接按会话递送凭证，仅放进 agent 内存，不能放在 argv、环境变量、日志或会话文件中。无可用凭证时会话等待重新授权，不默认落盘。accessibility 使用适合后台会话的 ThisDeviceOnly 策略并验证重启后首次解锁边界。
- 不读 `~/.kwwk`，不和 kk 共享；会话目录是 `~/Documents/wiki.qaq.apelin/sessions`。
- 登录状态的导出放到以后。

**本地工具**（owner 指定的基础清单，加上实现完整工作流所需的构建、安装与诊断提案）

| 工具 | 作用 | 风险 |
|---|---|---|
| `write_file` | 创建或整文件覆盖 | 写项目 |
| `patch_file` | 按 old/new 片段修补，带 diff | 写项目 |
| `create_file` | 新建文件（已存在则报错） | 写项目 |
| `read_file`、`list`、`grep`、`find` | 读 | 只读 |
| `run_code` | 在项目里执行命令或脚本 | 系统，见审批 |
| `analyze_framework` | 分析一个框架 | 只读 |
| `framework_header` | 取一个框架的头文件，来源是已注册的 SDK | 只读 |
| `build` | 构建项目，返回结构化诊断 | 执行工具并写项目；预设步骤/自定义脚本按下文分别判断 |
| `install` | 按产物 ID/摘要安装，返回事务与安装记录 ID | 系统；安装可能执行 root maintainer 脚本 |
| `remove_package` | 按安装记录 ID 卸载 Apelin 构建并安装的受管项目包，见 §8 | 系统；核心包与无匹配安装记录的包不在能力范围内 |
| `respring` | 重启主屏幕，返回重连信息 | 系统，预设允许 |
| `confirm_loaded` | 按构建标记、目标进程与库身份核对加载，分别返回日志/镜像证据 | 受限只读 |
| `read_logs` | 按项目 subsystem/目标进程读取有条数和时间上限的日志 | 受限只读 |
| `list_crashes`、`read_crash`、`symbolicate_crash` | 枚举报告 ID、读取报告、匹配项目 dSYM 与符号化 | 受限只读；宿主代理受保护报告读取 |
| `capture_screen`、`read_ui_tree` | 截图与 UI 树，返回附件或结构化结果 | 敏感读取，是否预设放行单独配置 |
| `ui_action` | 对指定目标执行一次点击、输入等结构化动作 | 系统；不因“UI 测试”默认放行 |

`analyze_framework` 和 `framework_header` 直接读 SDK 里的 tbd 和头文件，不需要在设备上跑别的东西。

**审批**：两档。
- *宽松*：全部直接执行。
- *需要确认*：项目内文件编辑直接放行；预设的读取和命令按具体能力匹配（含 respring）。其他系统工具、二进制或无法归类的脚本，每一步确认。`install`、`respring` 和 `confirm_loaded` 分成独立调用，串成工作流也分别判断。例外是 `confirm_loaded` 可以自己触发 respring（按 respring 判断），因为加载标记只在监听期间才能听到。
- 审批请求是一个事件 `approvalRequested`，agent 挂起等待；app 不在线时会话停在"等待审批"，不会默认通过；挂起必须响应取消。
- 预设列表放在设置里，可以由用户编辑。

**[设计]** 审批绑定具体工具、参数、工作目录与当前项目；参数改变须重新判断。项目内自动放行须经过 realpath/目录 fd 检查，不能通过符号链接写出项目。预设匹配结构化调用，不能只按命令前缀匹配复合 shell；不能分类的脚本在“需要确认”模式下请求确认。agent 不能修改自身审批预设。模型输出和扩展描述都不是放行依据。

**Confirm 的 build/install 默认值（owner 2026-10-16 决定）**：构建与安装用同一条规则——和模板一致就放行，改过就在改后第一次审核。
- **构建**：比较的是构建描述，不是源码：`apelin-project.json` 的构建步骤、编译/链接参数和项目携带的构建脚本。与项目来源模板的对应内容逐字节一致时直接执行；有改动时，改动后的第一次构建请求审核，卡片显示相对模板（或上次批准版本）的 diff。批准记录的是这份构建描述的内容摘要，摘要不变的后续构建不再询问，再改一次就再审一次。源码编辑仍按“项目内编辑直接放行”处理，不触发构建审核。
- **安装**：比较的是打包描述，不是编译产物：control 字段、maintainer 脚本、安装布局与包依赖。与模板一致时直接安装；有改动时第一次安装请求审核，卡片显示包 ID、产物摘要、改动 diff 和全部 maintainer 脚本，批准绑定打包描述摘要，此后同一摘要的安装不再询问。每次安装仍绑定本次产物摘要，由宿主复制到私有暂存后提交，防止确认后被替换。
- 批准摘要由宿主保存在私有状态中，按项目 ID 绑定；agent 和项目文件不能写入或伪造。模板本身升级后，旧项目仍以其登记的模板版本为基线。
- 受管包卸载不在本决定内，Confirm 下仍逐次确认。Relaxed 照旧全部直接执行。

**宿主执行策略 [设计]**：agent 只能请求上述任务级能力，build/environment 只提交进度与产物，扩展只返回其工具结果；工作进程没有受保护写、交互 PTY 控制或任意 root 执行接口。宿主持有审批状态，已批准产物由宿主复制到私有暂存并核对摘要后交安装服务，避免确认后可写 fd/原路径被替换。手动编辑授权和普通 agent 审批分别校验，不能互相代替。

**MCP**：只支持 HTTP。stdio 在 iOS 上被上游关掉了，要等上游 PR，里程碑 1 不做。

**skills**：内置 `tweak-development`、`packaging-and-install`、`crash-triage`；用户目录 `~/Documents/wiki.qaq.apelin/skills` 也读。system prompt 只列名字和描述，正文由 `read_skill` 按需读取（pi 的渐进披露）。

## 8. 构建、打包、安装

**构建流水线**：`apelin-build` 一次构建一个进程，以 mobile 运行，由会话宿主拉起，输出结构化事件（阶段、诊断、产物）。

计划阶段（既有实测使用临时工具完成了类似链路，产品实现仍待完成）：
1. 编译：每个源文件、每个架构各一个 `.o`
2. 链接：每个架构生成项目类型对应的可执行文件、dylib 或 bundle；App/设置面板再组装相应资源目录
3. 合并切片
4. 生成 dSYM（先编并保留 `.o`、链接后再生成，否则一步完成编译链接时拿不到调试信息；旧实测仅确认工具能运行，完整调试符号仍需用已知地址做符号化验收）
5. strip
6. 签名：**必须是最后一步**，之后任何修改都会使签名失效

编译参数沿用 platformize-tweak-ios 的规则：`-Werror=unguarded-availability-new`、`-fvisibility=hidden`、`-ffile-prefix-map`，部署目标 16.0。

**路径** [已验证]：工具链没有链接 libvroot，看到的是真实根目录。`-isysroot` 等参数必须传 jbroot 的物理路径，不能传 jbroot 视角的路径。物理路径由 apelind 的 `hello` 给出。

**签名**：复用 Irisin 的 `LdidStyleSignature`，原调研记录有与 `ldid -Hsha256 -S` 对照的夹具；复用时保留夹具，并增加本项目产物和设备安装后的运行验证，不能将夹具等价扩大为任意镜像的兼容保证。签名放进共享模块，不依赖 ldid 二进制；ldid 不进主包。

**打包**：自己写 deb 写入端（ar 容器包含 `debian-binary`、control 归档和 data 归档），五件套里没有现成的写入端。控制文件、压缩格式、权限和链接条目以 Irisin 读取端可接受的格式为验收依据；逐类产物做往返检查。control、maintainer 脚本、`@PREFIX@` 规则沿用现有模板并适配项目类型。设备产品不调用 dpkg-deb；仓库现有的 Mac/CI 打包工具不在本次替换范围内。

**安装**：一律打包后交给 Irisin 的守护进程。
- 需要改 Irisin：把 Irisin 专属可执行路径白名单改为已约定的 jailbreak 根/系统可信路径范围，保留 audit token、允许的 euid、必要 entitlement、root 所有且不可被组/其他用户写的可执行文件检查。路径先规范化后按组件比较。**固定安装桥接方选为 `apelind-session`**：宿主执行审批、固定包内容后直接作为 irisind 客户端；app 的安装操作仍通过 apelind 控制面进入宿主。build/agent/扩展不持有 Irisin 客户端 entitlement，不直接提交安装。
- Irisin 发新版，Apelin 依赖这个版本；在此之前，设备上的联调用 dpkg 代替。**[现状]** 已完成：Apelin 依赖 Irisin 4.7.0，所有安装和卸载都经 irisind。
- Apelin 里不出现对 `apt`、`dpkg` 二进制的调用（实测阶段的 dpkg 只是临时手段）。

**[设计]** 安装桥接包含服务版本/能力握手、包 fd 提交、事务 ID、进度、结果和 app 重连查询；重复提交同一个已完成事务不能重复安装。Irisin 的实际协议需在 A 阶段核对，缺项列入其新版本工作，不能把现有 `run` 当作已支持完整恢复。B 的工具链安装也依赖此桥接，手工 dpkg 联调不计入里程碑验收。

**受管包卸载 [设计]**：`remove_package` / `removePackage` 接收宿主登记的 `installationID`，由宿主解析包 ID；仅覆盖 Apelin 自己构建且经本安装桥接成功安装的项目包。登记由宿主保存于其私有状态目录，绑定项目/构建 ID、产物摘要、包 ID、版本、安装事务与安装服务回执，mobile 项目清单不能伪造所有权。卸载前与当前安装状态核对；版本被外部替换、记录缺失或身份不符时返回不可受管，转交用户的包管理器处理。

bootstrap 核心包、安装服务、Apelin 自身及受保护系统包始终不属于项目卸载范围；安装项目包时也检查保留包 ID 与已有非受管包冲突，防止先覆盖再取得“自己的包”身份。卸载计划只包含选定受管包，依赖检查不通过时拒绝，不递归卸载其他包。工具链/SDK 删除使用各自的环境管理入口。此能力范围对两档模式一致；Relaxed 仍直接执行范围内的操作，Confirm 是否确认由 §7 决定，不提供通过确认越过范围的例外。A1 验证无效记录、外部升级、核心包冲突与依赖连带删除均被拒绝。

**Irisin 信任边界 [设计，A1 两仓同步]**：路径范围放宽按既定产品方向推进，但其含义是信任满足检查的已安装包，不是只信任 Apelin。模型里把已能安装、自签并取得 root-owned 可执行文件的包视为受信任的系统参与者；entitlement 是调用资格声明，不是已安装包之间的身份隔离。Apelin 生成并装入的 CLI 也可能满足这些条件，恶意已安装包、root 或被篡改的安装服务不在 Apelin 审批机制可防御的范围内。审批保护的是经 Apelin 发起的工作流，不能承诺阻止有同等系统能力的软件绕开它。A1 必须把这一模型写入 Irisin 的鉴权文档、Apelin 的实现决定及测试用例；若产品需要隔离已安装包，需重新决定不可自声明的身份/能力机制，不能靠 entitlement 名称补足。

**respring 与确认加载**
- respring 走 apelind 的封闭操作。
- 确认加载三管齐下：插件里打一条带标记的日志；读目标进程已加载的库（Inspector 的做法）；静态检查过滤条件。
- **[现状]** 只剩两管：日志标记和过滤条件的静态检查。读 SpringBoard 的已加载库让 iOS 27.0.1 内核 panic 了三次（task port 读 dyld image infos 两次，region path 遍历一次），两种读法都已删除，镜像证据永远是 `notRead`。`confirmLoaded` 是宿主持有的任务，respring 不会丢掉答案。记录见 `Documents/Research/Device-Validation.md`。
- **[设计，待验证]** 重启循环恢复只针对本次安装的包，关联安装事务、进程重启和崩溃记录；不能因其他插件崩溃自动卸载无关包。停用方式必须由注入框架或模板明确支持，不能假定任意“开关文件”都有效；没有可靠停用接口时通过安装服务回滚/卸载，并提供界面外可用的恢复路径。恢复动作遵循用户选择的审批模式及已授权的恢复策略。

## 9. 调试

里程碑 1 只做简单调试，不做断点调试器。

**icli 优先（owner 2026-10-16 决定）**：凡是 `owngoal-dev/icli` 已经能做的，一律用 icli，借此 dogfooding icli。按 icli README 当前列出的能力，覆盖：系统日志、崩溃报告读取、截图与 OCR、UI 树、点击/输入/滑动等 UI 动作、前台 app 与进程、已装 tweak 列表、重启 SpringBoard（respring 兜底）。缺什么、哪里不好用，在 icli 仓库补，不在 Apelin 里另写一份。仍由 Apelin 自己负责的只有 icli 没有的：崩溃符号化与嫌疑排序（XrashKit）、目标进程已加载库的核对（Inspector 的做法，icli 有了就换）。A2 逐项核对上面每个能力在 icli 里的实际 API 和所需 entitlement。

- **日志**：宿主管理 `apelin-diagnostics`，读取系统日志并按项目 subsystem/进程过滤，经 `logStream` 和 `read_logs` 输出。日志读取用 icli；界面复用已有应用日志查看器，不把“查看器”当成系统日志读取实现。
- **崩溃**：复用 XrashKit 的解析、符号化、嫌疑排序。受保护的报告由宿主按报告 ID 打开，只传只读 fd，普通可读报告无需提升权限。符号化用项目构建时保留并匹配 UUID 的 dSYM。
- **加载确认**：见 §8。
- **UI 验证**：通过 §7 的截图、UI 树与动作工具验证可见效果，复用 icli 对应模块；图像作为受限附件返回。公共 XPC 上的 `captureScreen` / `readUITree` / `uiAction` 供 app 的“手动 UI 验证”页面使用，app 的显式操作经宿主校验目标会话后转发给 mobile 诊断进程；root proxy 不直接执行 UI 自动化。agent 的同类请求只走内部通道，并按 §7 独立审批，不得声明成 app 手动操作。target ID 绑定本次验证的目标，动作采用固定类型与参数，不接收任意命令。
- **icli 边界 [设计]**：来源是 `owngoal-dev/icli`（MIT），以 Swift package 引入 `IcliKit`、`IcliSystem`、`IcliLaunch` 中需要的产品，版本列入 §11。首选把所需模块链接进 mobile 的 `apelin-diagnostics`，由宿主经固定内部协议请求；若开发期使用 CLI，则由该工作进程调用安装时确定的固定 icli 路径及限定参数，不接收 agent 提供的任意子命令。A2/F 验证各能力所需 entitlement 和 UID，未验证组合标为不可用。icli 及其依赖只在 mobile 工作进程内运行。
- **root 日志读取 [设计]**：仅当目标日志确需 root 时，由宿主从固定已安装路径启动图中的 `apelin-log-reader`。它只链接系统库，不链接 `IcliKit`、`IcliSystem`、libarchive 或其他第三方库，也不 exec icli。输入限定为宿主已核对的日志过滤条件/时间窗口，输出为有界日志记录；它不接收可执行路径、通用文件路径或 UI 操作。受保护崩溃报告仍由宿主按 report ID 只读打开，再交 mobile 进程解析。A2 检查 root helper 的链接与加载依赖，F 验证数据范围、限额和取消；没有可用系统读取实现时保留明确的能力缺失，不以提升整个诊断进程代替。
- **文件描述符编辑**：复用 Fila 的 `AtomicSave`，受保护编辑仅走 §2 的 app 手动授权、有限 scope 和 `protectedEditCommit`；agent 的项目内保存以 mobile 权限完成。

## 10. 界面

- iPhone 和 iPad 共用标准侧边栏分栏视图（`UISplitViewController`），按 iPad 的布局设计，iPhone 收缩。
- 页面：项目、文件、构建、日志与崩溃、终端、git、agent、设置（工具链、SDK、扩展、模型、审批）。
- 根采用标准侧边栏分栏，iPhone 收缩为导航；`AGENTS.md` 的 root 决定已同步区分当前脚手架与 M1 目标。
- 设计风格借五件套：Irisin 的分栏和设置控制器，iGhostVT 的设计令牌。先出一版，再和 owner 一起改。
- **高性能列表与富文本（owner 2026-10-16 决定）**：参照 FlowDown 的做法。长列表（agent 对话、构建日志、系统日志、文件列表）用 `Lakr233/ListViewKit`；agent 消息的 Markdown 渲染用 `Lakr233/MarkdownView`，底层文字排版用 `Lakr233/Litext`；流式输出和日志刷新按屏幕刷新节奏合帧，用 `Lakr233/DisplayLink`，不在每个事件上刷 UI。FlowDown 本身是 AGPL，只参照它的用法，不复制它的代码；四个库各自按 §11 审阅许可。四个库的 `Package.swift` 最低 iOS 15/16，满足 16.0 的 floor；ListViewKit 的仓库简介写着 iOS 17+，A2 在 iOS 16 上实测后以实测为准。
- 编辑器（owner 2026-10-16 决定）：v1 只做基础编辑，基于 `Runestone.xcframework`：打开、编辑、保存、撤销、查找替换、语法高亮（tree-sitter，补 ObjC 语法）。不做代码补全、提示和定义跳转，不接 LSP。构建诊断在构建日志里列出文件和行号，点开跳到对应行。 **[现状]** 改为照 Irisin 的做法 vendor 源码（`Packages/Runestone`），只留 iOS 开发和常用脚本的 13 种语法（含新补的 ObjC、XML、Make），xcframework 已移除。
- 终端：简单为主。基于 iGhostVT 的终端视图和 PTY 会话（libghostty）。
- **clangd 不进 v1（owner 2026-10-16 决定）**：它是内存和 CPU 的大户。第一版去掉，相关的编译数据库、LSP 进程和语言服务都不做；以后再加时单独立项。
- **[设计] git**：基于 libgit2（§4）。B 阶段复用底层获取能力，I 阶段交付状态、diff、stage/unstage、本地 commit；GitHub 账号连接、远程写入及自动管理仓库放后续，与已拍板的源码包延期一致。
- 无障碍：按 `AGENTS.md` 的全部规则，`make check` 里的无障碍检查要过。

## 11. 轮子清单（待审批）

owner 的原则：优先用乌龙工作室现有产品里的轮子。审批前不搬。

| 能力 | 来源 | 用法 | 要改什么 |
|---|---|---|---|
| Agent / MCP | 原调研中的 kwwk：`KWWKAgent`、`KWWKMCP` | 只链接到 mobile 的 `apelin-agent` | 固定仓库/版本，验证 iOS 产品；适配事件序列化、执行后端、可取消审批；核对完整传递依赖 |
| 归档读取 | Irisin/Fila 使用的 libarchive 及其压缩依赖 | `apelin-environment` 处理 xar/cpio/zip/tar.xz/tar.zst；安装读取复用既有模块 | 逐格式验证实际构建能力；pbzx 单独确认并补最小适配器；校验解包限额 |
| 归档压缩与 deb 写入 | 现有 libarchive、xz/zstd 组件优先 | 在 mobile 的 environment/build 中生成 control/data 归档与 ar 容器 | 明确写入压缩格式、Irisin 兼容性、依赖版本/许可；已有库缺对应功能再加依赖 |
| 终端引擎 | iGhostVT/Fila 使用的 `libghostty-spm` | 复用 app 的终端引擎 | 固定同一版本、核对 iOS floor 和传递许可；与 PTY 宿主区分 |
| 语法解析 | Runestone/tree-sitter 与 ObjC grammar | 编辑器高亮 | 列出引擎和每个 grammar 的来源/版本/许可；补 ObjC，避免重复 vendor |
| 日志、崩溃读取、截图、UI 树与动作、respring 兜底 | `owngoal-dev/icli` 的 `IcliKit`、`IcliSystem`、`IcliLaunch` | §9 的 mobile 诊断工作进程；能用 icli 的一律用 icli（dogfooding） | 核对 API、UID/entitlement、模块依赖与 MIT 通知；缺口在 icli 补；不链接进 root 日志 helper |
| 高性能列表与富文本 | `Lakr233/ListViewKit`、`Lakr233/MarkdownView`、`Lakr233/Litext`、`Lakr233/DisplayLink`，用法参照 FlowDown | agent 面板、构建/系统日志、文件列表 | FlowDown 是 AGPL，只参照不复制；MarkdownView 的许可显示为 Other，及其依赖（SwiftMath、swift-cmark、swift-collections、LRUCache）逐一审阅；ListViewKit 在 iOS 16 实测 |
| root 日志读取 | 系统日志 API，最小读取适配新写 | `apelin-log-reader`，仅在确需 root 时由宿主启动 | 只用系统库，固定过滤协议；A2 审核依赖、F 验证读取权限和限额 |
| hook 开发接口 | 所选注入框架兼容 API 的 headers 与 `.tbd` | 打进 tweak 开发扩展 | 固定来源与许可；核对 API/架构/运行时虚拟包，补真实 hook 测试 |
| 终端视图、PTY 会话、会话宿主分层 | iGhostVT：`LockableTerminalView`、`PTYSession`、`SessionRegistry`、`IOSupervisor`、`iGhostVTProtocol` | 参照其分层；终端视图直接搬 | 去掉 relay 和远程；改名 |
| 终端（简化备选） | Fila：`FilaTerminal` | 不用 | 里面有 `dpkg -i` 的调用 |
| fd 传递与原子保存 | Fila：`AtomicSave`；参考 `openPath` / `replaceItem` 的 fd 传递方式 | 只复用 `AtomicSave` 机制；打开/替换服务按 §2 的授权模型重写 | scope/grant、调用方、文件版本/内容绑定与提交复核；不搬任意路径 root 写接口 |
| 文本编辑器 | `Runestone.xcframework`；Fila：`TextViewerViewController`、`TextSyntax`、`FindBar` | 直接搬，只做基础编辑 | 补 ObjC 语法；不接 LSP |
| 十六进制、plist 查看 | Fila：`HexViewer`、`Plist` | 可选 | |
| Mach-O 读取 | Fila：`FilaFormats/MachOImage`（MachOKit） | 直接搬 | |
| Mach-O 改写与签名 | Irisin：`MachOBinary`、`LdidStyleSignature`、`LdidEntitlements` | 抽成共享包 | 类型改 public；补改平台、改路径、加 rpath |
| deb 读取 | Irisin：`PackageArchive`、`DebianControl`、`DebianVersion`；AptRepository 的 `ArchiveStream` | 直接搬 | |
| deb 写入 | 无 | 新写 | |
| 安装 | Irisin：irisind、`IrisinProtocol`、`InstallerJob` | 宿主作为服务客户端，采用系统库可实现的 wire 适配 | 同步信任模型与鉴权；核对桥接模块不把第三方库带进宿主；发新版 |
| 崩溃解析与符号化 | Xrash：`XrashReport`、`XrashSymbols`、`XrashBlame` | 直接搬 | `DpkgIndex` 读 `/var/lib/dpkg/info`，要换掉 |
| 加载库检查 | Inspector：`DetailSampler`（`dyldImages`） | ~~搬相关部分~~ **[现状]** 不用：读镜像列表会让内核 panic，见 §8 | — |
| 分栏、侧边栏、设置 | Irisin：`SplitInterfaceController`、`SidebarController`、`SettingsController`；iGhostVT：`DesignSystem` | 参照 | |
| 对等鉴权 | 各 daemon 的 `PeerAuthenticator`（已在脚手架里） | 已有 | |
| 系统日志流 UI/传输 | 现有应用日志查看器与上述 icli 读取适配 | 项目过滤、宿主事件流与界面新写 | 固定过滤能力，和读取模块分别验证 |
| git | libgit2，经新建的 `Lakr233/libgit2.xcframework`（照 `Lakr233/libarchive.xcframework` 的做法） | Git 适配层和界面新写 | A2 建仓出版本并审阅许可（libgit2 为 GPLv2 附 linking exception，及其编进去的依赖），B 交付 SDK 获取，I 交付界面 |
| SDK 来源 | `owngoal-dev/iOS-SDKs`，由 `xybp888/iOS-SDKs` fork 后 detach | 默认 SDK 来源，一 SDK 一分支 | A2 建仓、改布局、写致谢；Apple SDK 条款见 §12 |

**重复代码**：Runestone 在 Irisin 和 Xrash 里各 vendor 了一份且不同，Apelin 统一用 `Runestone.xcframework`，不搬任一份源码；`MachOImage` 在 Fila 和 Xrash 里是分叉，搬进来时取一份，抽成共享包，不再产生第三份。 **[现状]** 已改为 vendor 源码并裁剪语法（`Packages/Runestone`，取自 Irisin 那份），见 `AGENTS.md` ▸ UI dependencies。

## 12. 许可

- Apelin 本体 MIT。主包里不放 GPL 和 AGPL 的代码，不链接。
- **ldid**（AGPL）：不进主包，用 Irisin 的 Swift 实现代替；实测阶段在设备上临时装过。
- **Apple 的二进制和 SDK**：产品决定是不托管、不再分发。工具链由设备从 Apple 下载，Apelin 的包里不带 Apple 二进制和 SDK。SDK 的默认来源改为我们维护的 `owngoal-dev/iOS-SDKs`（§4），这意味着乌龙的组织在 GitHub 上托管 Apple SDK，此前“Apelin 不托管 SDK”的前提变了：建仓前核对 Apple SDK 的条款和 GitHub 的政策，记录结论；README、depiction 是否链接该仓库随结论定。这些设计不等于已取得修改、使用或分发许可。二阶段的工具链导出也必须单独审阅。**[待定]**
- **GPL 工具**：按选定版本的实际许可证分类，不根据工具名字推定。主包保持不链接 GPL/AGPL；独立扩展须保留通知、提供所需对应源码与构建材料。独立包、独立进程和数据协议是拟采用的边界，是否构成一个组合程序仍取决于交互语义，不能作为自动免责结论。[GNU GPL FAQ：聚合与通信边界](https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation)。
- 新依赖（libgit2、kwwk 及其传递依赖 NIO、BoringSSL、stb、libwebp 等）：进 `Licenses/` 和 `review.json`，由 `collect-licenses.py` 校验。
- 从 Irisin 抽出的共享代码：核对许可和文件头，保留原有版权、许可与必要署名；“统一”只指包内组织与通知收集，不删除原作者信息。

## 13. 工作分解与顺序

实施阶段结束时跑 `make check`、`make harness`；涉及设备的在两套 vphone 上实测，涉及包布局的跑 `make deb-all`。本次仅做文档核对及仓库静态检查。文中“A 阶段”统指下面的 A0/A1/A2，各自独立验收。

| 阶段 | 内容 | 依赖与退出条件 |
|---|---|---|
| A0. 协议、宿主与权限 | proxy/宿主与内部工作进程通道；按需拉起的生命周期；事件重放/取消；scope/grant 与审批状态；PTY 降权；项目/模板 schema | checklist 通过；有工作不退出、空闲才退出，退出后再拉起能恢复任务；仅 app 能连公共 XPC；伪造角色/越界 scope/过期授权被拒绝；worker 无 root 写或 PTY 控制能力；终端 UID/GID/继承 fd 正确；断线重连与取消测试通过，schema 有有效/无效夹具 |
| A1. 安装桥接 | 宿主连接 Irisin；鉴权信任模型两仓同步；服务能力、兼容测试、新版及最低依赖 | A0 的协议边界；先用预制测试 deb 验证提交/跟踪/重连，不依赖 A2 写入器；审批绑定产物摘要；受管卸载与冲突用例通过；旧服务返回明确原因；验证已安装包的实际准入范围；实际新版可安装 |
| A2. 共享能力与选型 | 审阅 §11 清单；Mach-O/签名、fd 保存、归档与 deb 写入；`libgit2.xcframework` 建仓出版本；`owngoal-dev/iOS-SDKs` 建仓与布局；icli 能力核对；UI 库在 iOS 16 实测；钥匙串/诊断权限 spike | A0 接口约定；逐格式读写及损坏输入夹具通过；deb 可被 Irisin 读取；原子保存冲突测试通过；libgit2 浅克隆一个 SDK 分支成功；icli 各能力和钥匙串/诊断身份各有实测结论及依赖许可记录 |
| B. 工具链与 SDK | 设备下载、解包、改造、本地包安装、验证注册；SDK 下载/导入/自查；最小环境设置页 | A0/A2 后即可开发，正式验收依赖 A1；git 获取后端在本阶段交付。干净设备无 Mac、经 Irisin 完成安装，Swift 独立验收，开始真机和最低系统验证 |
| D1. 项目最小闭环 | 开发扩展发现、项目描述、自查；固定来源的 ObjC Hello 模板 | A0 schema、A2 的共享能力；可先于 B 完成数据部分，配合 B 生成一个可以构建的项目 |
| C. 构建与安装 | 编译、链接、dSYM、签名、deb；安装、respring、加载确认 | B、D1、A1；通过界面完成 Hello 链路，已知地址能符号化，取消和重连通过 |
| D2. 四类扩展 | App、tweak、CLI、设置面板拆包与全部模板；升级卸载 | C、D1；每类通过 §5.5 验收，缺失扩展不损坏现有项目 |
| E. 界面 | 分栏、项目、基础编辑器、终端；构建日志及安装页；ListViewKit/MarkdownView/DisplayLink 的列表与渲染 | 骨架 A0 后开始，B/C 所需最小页面随对应阶段交付，完整验收依赖 C；iPhone/iPad 操作、无障碍通过；长日志和流式输出滚动不掉帧 |
| F. 调试 | 系统日志、崩溃符号化、加载确认、UI 验证及恢复入口 | C、E；已知崩溃与 dSYM 对应，安装成功与加载成功分别呈现 |
| G. agent | kwwk 事件和执行后端适配；会话持久化；本地工具；审批；模型与钥匙串；面板 | A0/A2、C、E；agent 完成改码到加载确认，app 退出/重连不丢事件，等待审批可取消；宿主拒绝伪造批准和绕过工具入口 |
| H. 代理工具扩展 | 版本化协议、附件 fd、取消；反汇编扩展及许可材料 | G、许可审阅；真实工具调用、坏帧、崩溃和权限隔离检查通过 |
| I. git 界面 | 状态、diff、stage/unstage、本地 commit | B 的 git 后端、E；操作真实仓库，错误与冲突不丢修改 |
| J. 联合验收 | 两套 vphone 全链路；roothide/rootless；真机、最低系统、恢复与资源压力回归 | A0/A1/A2 至 I 的交付项及 §1 完成标准全部有证据，设备矩阵的未测项不写通过 |

**[现状 2026-10-17]** A0、A1、A2、B、D1、C、F、G、H 完成了数据层部分，I 完成了后端；各阶段写着“通过界面”的验收项仍待 E。D2 的四个扩展都已打包，App、CLI、设置面板模板未逐类做 §5.5 验收。J 未开始（rootless、真机、iOS 16）。

**依赖主线**：A0 → A2 → B 开发；B 的正式验收与 A1 汇合，再与 D1 汇合进入 C → E → G → H → J。D2、F、I 也必须在 J 前完成；这只是依赖主线，没有工期估算前不宣称它是计算所得的最长关键路径。真机 spike 从 B 开始，J 做回归。

**开发期与验收分开**：A1 发版前，B 可开发下载、改造、SDK 与设置页面，并由测试人员用 dpkg 手工安装产物联调，记录为“临时安装路径”；产品代码不增加 dpkg 分支。安装服务可用未发布构建进行协议联调，但 B/C 正式验收必须重跑已发布 Irisin 服务的界面链路。这样外部发版不会挡住 B 的全部开发，也不会用临时结果替代交付要求。

**A1 测试包来源**：使用仓库 Mac/CI 打包工具预制的自有最小测试包（无 Apple 文件、无注入需求，使用独立测试包 ID）。保留源码/生成说明、预期内容和 SHA256，A1 从夹具登记受控的测试构建/安装记录，测试记录仅存在于隔离测试环境，不为产品增加“任意包认领”入口。A2 写入器完成后再生成同等包重跑桥接测试，因此 A1 开始联调不依赖 A2 的 deb 写入实现。

**估算**：agent 层（G）按原 kwwk 调研是 6 到 8 人周，尚未重新评估，不是里程碑总工期。A 结束按实际选型拆任务并估算，B 的设备端和真机 spike 后再校正；不把待验证兼容性当作已知工作量。

## 14. 风险与待定事项

**风险**
1. 设备端改造是本计划最大的工程量，而且实测时是在 Mac 上改造再传过去的，设备上就地改造还没做过。**[现状]** 已在两台 vphone 上就地完成。
2. 所有设备实测都在 vphone 研究内核上；签名策略、TXM、roothide 安装时的自动重签在真机上可能不同。B 阶段就上真机，不等 J；无真机结果不宣称正式支持。
3. arm64e 指针签名的 ABI 在真实注入下是否被接受，没有验证；arm64e.x1 只验证了编译和链接，没验证运行。
4. 编译器的内存峰值在 4 到 6GB 机型上是否触发 jetsam，没有测。
5. xcodebuild 不能搬（100 个 IDE 框架依赖 macOS 专有框架）。Xcode 工程只能当文本编辑，不能在设备上构建。
6. 社区 SDK 的来源没有许可声明，随时可能消失。
7. Swift 编译器与 shim、iPhoneOS 兼容库尚未通过设备运行测试；第二套 vphone、rootless 与 iOS 16 组合也未验证。
8. Irisin 新版本服务能力和发布是 A1 的外部依赖，影响工具链首次安装与产品安装链路；当前不能填造一个最低版本号。**[现状]** 已解决：Irisin 4.7.0。
9. 解包峰值空间、任务日志增长、多个 agent 和构建同时工作的内存压力未测。任务调度需要限并发和明确的失败恢复，不使用“子进程无内存上限”作为保证。

**待定**

| 项目 | 当前提案/依据 | 解决阶段 |
|---|---|---|
| 复用清单与共享包边界 | §11 仍待 owner 审阅；先核对来源、许可证和文件头，再搬代码 | A2 |
| SDK 仓库的托管条款 | `owngoal-dev/iOS-SDKs` 建仓前核对 Apple SDK 条款与 GitHub 政策 | A2 建仓前 |
| 钥匙串读取 | 专属 access group 优先，失败时采用内存递送；实测后台、锁屏和首次解锁行为 | A2 spike、G 验收 |
| SDK 来源语音歧义 | 原回答“不会从旁边的 Logo 里面去导入”尚未确认含义；不据此增加“拒绝来自 Xcode 的 SDK 文件”限制。已明确的社区下载和文件导入照常设计，Xcode 专用提取流程不列入 M1 | 若提出额外来源限制，再确认原意 |
| 工具链版本矩阵 | 用 CLT 27.0 的已有记录起步，不保证其在最低系统运行；确认 Swift shim 和兼容库缺口 | B |
| 四类模板来源 | 固定仓库、commit、许可、依赖与适配差异；§5 的包名/字段是草案 | D1/D2 |
| Irisin 服务与最低版本 | 保留完整鉴权条件；核对任务恢复能力；由实际发布版本填最低依赖 | A1 |
| Apple/SDK 及扩展许可 | 审阅实际条款、来源授权、GPL 通信边界与对应源码交付 | 获取/复用前核对，发布前完成 |
| 代理扩展独立界面 | 建议里程碑 1 仅做工具调用及结果展示，不加载第三方 UI | H 前审阅 |

**不再重复询问的决定**：设备端 CLT 改造、可选 Swift、四类开发扩展、Irisin 安装、两档审批、终端/git 进入 v1、clangd 不进 v1、git 用 libgit2、项目固定在 `Projects/<name>`、daemon 按需拉起、SDK 默认来源为自维护仓库、所有包双 bootstrap 进仓库索引、诊断优先 icli、源码包与 DCRM 不做，均已有 owner 决定。§2 的工作进程拆分作为实现提案执行核对，不把已经选定的 agent 子进程方案再列成产品选择。用户文案继续使用通用包管理器表述；内部协议文档按 `AGENTS.md` 已有 Product 决定描述 Irisin。

## 15. 审阅结论与验证记录

本次对照外部审阅修订了以下约定，均属于设计文档，不代表对应功能已实现：

- §2：app 是唯一公共 XPC peer；工作进程仅经内部通道，明确文件 scope、手动编辑授权和 mobile PTY。
- §7–§9：审批由宿主执行，安装桥接固定在宿主；补齐日志、崩溃、UI 与加载确认工具，并明确 Irisin 的已安装包信任边界。
- §5/§11：补 hook headers/stubs、Agent、归档/压缩、语法解析、终端引擎与 icli 的来源、进程归属和审阅项。
- §10/§13：同步 root 导航决定；拆分 A0/A1/A2，修正 E → G 依赖，区分 B 的开发联调与正式验收。
- §14：已有产品决定保持不变，Confirm 安装默认值等未决项单独标记，不由模糊措辞代为决定。

**第二轮审阅修正**：进程图补齐只用系统库的 root 日志 helper，并修正对齐；§11 改为仅复用 Fila 的原子保存机制；§2 的受保护编辑范围改标待定；§9 明确公共 UI 操作供手动验证页面使用并由 mobile 进程执行；§8 的卸载限定为有匹配记录的受管项目包，排除核心包及连带卸载；A1 采用预制测试 deb，解除对 A2 写入器的隐含依赖。

**owner 委托决定（2026-10-16）**：受保护编辑范围按 §2 定为 bootstrap 安装根内的已有普通文件，只替换内容、先备份、无删除接口，仅 LaunchDaemons plist 额外确认；已从 §14 待定中移除。

**owner 决定（2026-10-16）**：Confirm 模式下构建与安装的默认值已定，见 §7：与模板一致直接放行，改过则改后第一次审核、按摘要记住批准；已从 §14 待定中移除，并同步 `AGENTS.md` ▸ Product ▸ Approval。

**owner 第三轮批注（2026-10-16）**，均已写入正文并同步 `AGENTS.md`：
- §1/§10：界面参照 FlowDown，用 ListViewKit、Litext、MarkdownView、DisplayLink；FlowDown 只参照不复制。
- §2：apelind 按需拉起，有工作不退出，去掉 `KeepAlive`。
- §2/§9/§11：诊断与 UI 操作能用 icli 的都用 icli。
- §2/§5.3：项目根固定在 `~/Documents/wiki.qaq.apelin/Projects/<name>/`。
- §3.2：工具链安装完成时自动自检。
- §3.2/§10/§13：clangd 不进 v1；编辑器只做基于 `Runestone.xcframework` 的基础编辑。
- §4/§12：SDK fork 到 `owngoal-dev/iOS-SDKs` 并 detach、自维护、致谢原作者；托管条款列为待定。
- §6：所有包出 rootless/roothide 两个 deb，进仓库索引。
- §4/§11/§14：git 后端定为 libgit2，在 `Lakr233/libgit2.xcframework` 维护。

**实施时的验证记录**：每个测试组合记录系统版本、bootstrap 类型、目标架构、工具链/SDK ID、Apelin/Irisin 版本、步骤、预期/实际、产物 UUID 与日志摘要。使用不含设备标识的编号引用本地连接配置。产品全链路、Swift、rootless、真机和最低系统保持未完成状态，直到相应记录存在。原始聊天导出保存在仓库外，不作为计划附件提交。
