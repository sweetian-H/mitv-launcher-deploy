# mitv-launcher-deploy

> 小米电视 / 小米盒子第三方桌面（launcher）部署与定制技能包 —— 无 root、不刷机、不搬系统分区。

把 PatchWall 换成自己的桌面，但保留小米系统该有的东西（设置、投屏/米联、小爱语音）。这个技能包把实际踩过的坑固化成可复用的流程、脚本和查错表——不是又一篇"装个 APK 就行"的教程。

已在 **小米电视 4A（Android 6 / API 23，Amlogic 平台，`ro.build.type=user`，无 su）** 上完成端到端验证。

---

## 它解决的四类硬问题

| # | 问题 | 常规做法 | 本方案 |
|---|---|---|---|
| 1 | **权限封锁**：`pm disable-user` / `enable` / `hide` 对 shell(uid=2000) 全部 SecurityException | 找 root、刷开发版 | 改用 `settings put` / `am force-stop` / `pm clear` / `pm uninstall --user 0`（仅第三方），并**替换桌面本身**而不是禁用系统桌面 |
| 2 | **老运行时**：现代代码一启动就 `NoClassDefFoundError` / `NoSuchMethodError` | 抬 `minSdk`（导致装不上） | `coreLibraryDesugaring` + 关 R8 + 单个 `Compat` 类收敛全部 21 处 API 门 |
| 3 | **HOME 键归属**：系统默认桌面按钮改不动 | `cmd package set-home-activity`（会被厂商回滚） | 编译期改写 applicationId 命中厂商白名单，走 Resolver 选"始终"，重启保持 |
| 4 | **信源切不了**：HDMI3 / AV / DTMB 不在 `tv_input` 注册表里 | 死磕 `TvInputManager` | 直接打厂商私有 Activity + 私有编号（HDMI1=23 / HDMI2=24 / HDMI3=25 / AV=2） |

---

## 快速开始

### 方式一：作为 WorkBuddy 技能使用

```bash
git clone https://github.com/sweetian-H/mitv-launcher-deploy.git \
  ~/.workbuddy/skills/mitv-launcher-deploy
```

Windows:

```powershell
git clone https://github.com/sweetian-H/mitv-launcher-deploy.git "$env:USERPROFILE\.workbuddy\skills\mitv-launcher-deploy"
```

之后在对话里说「在小米电视上换第三方桌面」「CleanYourTV 装上了但 HOME 键不生效」「HDMI3 切不过去」，技能会自动加载。

### 方式二：只用脚本（不依赖任何 Agent）

```powershell
# 1. 侦察：七项事实一次性拿到，输出部署前必读的判定
powershell -ExecutionPolicy Bypass -File .\scripts\inspect-device.ps1 -TvIp 192.168.2.28

# 2. 构建（自动写 local.properties、可选 Gradle 镜像、校验 applicationId 是否真被改写）
powershell -ExecutionPolicy Bypass -File .\scripts\build-launcher.ps1 `
  -ProjectDir D:\src\launcher -LauncherId com.ts.launcher -UseMirror

# 3. 安装（自动驱动 MIUI 全屏安装确认框，避开"应用到全部"复选框陷阱）
powershell -ExecutionPolicy Bypass -File .\scripts\install-apk.ps1 `
  -TvIp 192.168.2.28 -ApkPath .\app-release.apk -ExpectedPackage com.ts.launcher

# 4. 配置：把 JSON 编译成 res/values/config.xml（配置文件推不进设备，见下文）
powershell -ExecutionPolicy Bypass -File .\scripts\gen-config-xml.ps1 `
  -Json .\assets\config.sample.json -OutFile .\app\src\main\res\values\config.xml
```

所有脚本**纯 ASCII**。这不是风格问题：PowerShell 5.1 读取无 BOM 的含中文 `.ps1` 会按 ANSI 解析，多字节字符会吃掉引号，报 `字符串缺少终止符` 之类的解析错误。

---

## 目录结构

```
mitv-launcher-deploy/
├── SKILL.md                          # 技能入口：工作流 + 红线 + 校验清单
├── references/
│   ├── 01-recon.md                   # 七项事实、权限矩阵、平台识别
│   ├── 02-api23-compat.md            # desugaring / R8 / 21 处 API 门 + Compat 实现
│   ├── 03-home-takeover.md           # 白名单机制、Resolver 持久化、Resolver 循环救援
│   ├── 04-input-sources.md           # 信源编号、私有 Action、接入弹窗的四个守卫
│   ├── 05-desktop-ux.md              # 苹果式排版参数、合成图块、图标生成规则
│   ├── 06-troubleshooting.md         # 症状 → 根因 → 修复 查错表
│   └── 07-rollback.md                # 回滚与不可恢复清单
├── scripts/
│   ├── AdbCommon.ps1                 # 共用：每次调用重连、UTF-8、按键封装
│   ├── inspect-device.ps1
│   ├── build-launcher.ps1
│   ├── install-apk.ps1
│   └── gen-config-xml.ps1
└── assets/
    └── config.sample.json            # 实测有效的配置规格
```

---

## 几个反直觉的结论

**1. 配置文件推不进设备。** `/sdcard/Android/data/<pkg>/` 归 adbd 的 UID 无所有权，`adb push` 一律 `EACCES`——即使目录是应用自己建的，`run-as` 也不行。所以默认值必须编译进 `res/values/config.xml`，改配置 = 重新打包安装。

**2. 小米不校验签名，只比对包名。** `MitvSettings.isThirdpartyHomeAllowed(pkg)` 是纯字符串比对。所以 `-PlauncherApplicationId=<白名单包名>` 就能合法接管 HOME，不需要冒充系统签名。

**3. `set-home-activity` 会被回滚，但 Resolver 选"始终"不会。** 用户显式选择写入的 Preferred Activities 优先级更高。机制本身就是解法。

**4. 别按型号猜平台。** 小米在相近型号上同时用过 Amlogic 和 MediaTek。很多公开教程默认 MediaTek（`com.mediatek.wwtv.tvcenter`），而该包名在 Amlogic 机器上根本不存在——照着配只会得到一行死配置。

**5. `dumpsys tv_input` 可能只注册两个 tuner。** 实测只有 `HW0`/`HW10`，HDMI3 挂在 `HW7` 却没注册，标准通道切不动是**固件事实**，不是代码 bug。

**6. 安装确认框的"应用到全部"复选框常常是预选中的。** 盲发 `CENTER` 会把它取消掉，安装随之取消。必须先 `DOWN` 再 `OK`。

**7. 桌面排版"第一行和下面不统一"的根因是 dock row。** 关掉 `dock_row`、开 `uniform_tiles`、常显名称、去掉浮动胶囊，一次就对齐了。

---

## 适用与不适用

**适用**：小米电视 / 小米盒子，Android 6–9，无 root；CleanYourTV 及同类基于 `TvInputManager` + app 列表的 launcher。

**部分适用**：其他 Android TV 设备（Sony / 海信 / Google TV）——`references/02` 的 API 兼容、构建参数、查错表通用；白名单机制和信源常量是小米私有，不可照搬。

**不适用**：手机 / 平板；需要 root 才能完成的目标（改系统分区、卸载系统应用）。

---

## 红线

- 不恢复出厂、不 `pm uninstall` 系统包、不动 `/system`——这三件事在电视上没有后悔药。
- 不假设有 `su`。`ro.build.type=user` 的机器没有任何提权路径。
- 改默认桌面之前，先确认能用遥控器走到「设置 → 应用 → 默认应用 → 主屏幕」，并在交付信息里写清原始桌面包名和回滚命令（见 `references/07-rollback.md`）。

---

## 验证过什么

在小米电视 4A 上的实际结果：APK 1963 KB → 2009 KB（开启 desugaring 后），HOME 接管后重启仍生效，HDMI1/HDMI2/HDMI3/AV/DTMB 五个入口实测均可切换（HDMI 直通黑屏属未接信号，正常），信源接入弹窗在真实连接事件上触发一次、开机不误弹。

**未覆盖**：部分固件不回调 `TvInputManager` 状态（机顶盒开机而电视停留在厂商应用时），需启用 3 秒轮询兜底——代码路径已写入 `references/04`，现场验证待补。

---

## License

MIT。见 [LICENSE](LICENSE)。

项目名与商标归各自所有者；本仓库不包含任何厂商固件、系统 APK 或反编译产物。
