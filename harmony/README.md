# 剪集 · 鸿蒙版（`harmony/`）

HarmonyOS NEXT（API 12+）原生输入法：把剪贴板历史做成键盘，点一下就插到当前输入框。
与仓库根的 Android 工程（`app/`）**完全独立** —— Gradle 不 include 这个目录，两套构建互不影响。

## 为什么必须原生（而不是继续用 APK）

- 鸿蒙 7 / HarmonyOS NEXT 不再原生跑 APK；卓易通是安卓兼容容器。**容器里的 APK 无法注册成系统输入法**：宿主鸿蒙的输入法框架只认原生 `InputMethodExtensionAbility`，看不到容器内的 IME。
- 所以 Android 版在鸿蒙上永远拿不到「默认输入法」这个身份；本目录就是给鸿蒙的原生实现。

## 目录结构

```
harmony/
├─ AppScope/app.json5                       # bundleName 与 Android 版一致：com.example.clipboardmerger
├─ build-profile.json5 / oh-package.json5 / hvigorfile.ts / hvigor/
└─ entry/
   ├─ build-profile.json5 / oh-package.json5 / hvigorfile.ts
   └─ src/main/
      ├─ module.json5                       # 输入法 Extension + UIAbility + 权限声明
      ├─ ets/
      │  ├─ InputMethodExtensionAbility/    # 输入法进程
      │  │  ├─ InputMethodService.ets       # InputMethodExtensionAbility 入口
      │  │  ├─ model/KeyboardController.ets # 创建面板 / 往编辑框插字
      │  │  └─ pages/Index.ets              # 键盘 UI（对应 Android 版 IME 面板）
      │  ├─ entryability/EntryAbility.ets   # 设置页入口
      │  ├─ pages/Index.ets                 # 设置页：权限 / 历史 / 日志开关 / 启用引导
      │  └─ model/                          # Logger.ets、ClipboardStore.ets
      └─ resources/base/profile/input_method_config.json   # 输入法子类型（决定系统输入法列表里的条目）
```

## 构建 / 装机（要在 DevEco Studio 里做）

1. DevEco Studio 5.0 及以上 → Open → 选本目录 `harmony/`（**不要选仓库根**）。
2. 首次打开会提示签名：`File → Project Structure → Signing Configs` → 勾选 **Automatically generate signature**（需华为账号实名登录）。
3. `Build → Build Hap(s)/APP(s) → Build Hap(s)`，产物在 `harmony/entry/build/default/outputs/default/entry-default-signed.hap`。
4. 手机开「开发者模式 + USB 调试」→ DevEco 里点 Run 直接装；命令行则 `hdc install <hap>`（hdc 在 DevEco 的 SDK 里）。

## 启用输入法

设置 → 系统和更新 → 输入法 → 勾选「剪集输入法」；打字时点键盘上的切换按钮选它。

## 与 Android 版的差异（平台约束，不是省事）

| Android 版 | 鸿蒙版 | 原因 |
| --- | --- | --- |
| 是默认输入法就能后台随意读剪贴板 | 需要 `ohos.permission.READ_PASTEBOARD`（受限 user_grant，可能要 ACL） | API 12+ 剪贴板读取加了权限管控；没授权时键盘仍可用，只是采集为空 |
| GitHub 同步在 App 内 | 暂未实现（实现位置应在本目录的 `EntryAbility` 侧） | 输入法 Extension 受「基础访问模式」约束：不允许网络/子进程 |
| 通知 + 悬浮气泡提醒（见 `PIT-031/032/033`） | 未移植 | 那套是绕开 Android 通知系统的手段，鸿蒙机制不同，按需再定 |
| `version.properties` 管版本 | `AppScope/app.json5` 的 versionName / versionCode | 两套构建各自管版本（发鸿蒙包时手工对齐） |

## 构建脚本 `build-harmony.bat`（在仓库根）

| 命令 | 作用 |
| --- | --- |
| `build-harmony.bat` | 只构建：`hvigorw assembleHap` → 产物收成 `build\harmony\JianJi-HarmonyOS-v<版本>-<build>.hap`（**不动 git**） |
| `build-harmony.bat release` | 递增鸿蒙版本号 → 构建 → `git commit/push` → tag `harmony-v<版本>` → `gh release create` 上传 HAP |
| `build-harmony.bat clean` | 清理 `harmony\.hvigor`、`harmony\entry\build`、`build\harmony`、根目录 `*.hap` |

- 日志：`build\logs\harmony_<ts>.log`（复用 `tools\tee-log.ps1`，逐行先落盘再回显，同 `build.bat`）
- 版本号真源：`harmony\AppScope\app.json5`（工具 `tools\harmony-version.js`）；与 Android 的 `version.properties` **各自独立**
- 脚本会自己找 DevEco（`C:\Program Files\Huawei\DevEco Studio` → `D:` / `E:` / `%LOCALAPPDATA%`）；装在别处就先 `set "DEVECO_HOME=<你的目录>"` 再跑
- Release 标签形如 `harmony-v1.89`，与 Android 的 `v1.88` 区分（同一仓库共享标签命名空间）

## 环境部署：只有一件事必须你来做

命令行构建**绕不开 DevEco Studio**（hvigor / node / ohpm / HarmonyOS SDK 都在它的安装目录里；公共 npm 与镜像上都**没有** `@ohos/hvigor`，已实测全 404）。而且**真机安装必须是华为签名的 HAP**：

1. 下载安装 **DevEco Studio 5.0+**（约 3~6 GB，下载需华为账号）：<https://developer.huawei.com/consumer/cn/download/deveco-studio>
2. 打开本目录 `harmony/`（**不要开仓库根**）→ `File → Project Structure → Signing Configs` → 勾选 **Automatically generate signature**（需账号实名。这一步会把签名材料写进 `harmony/build-profile.json5`，之后命令行构建同样能出**已签名** HAP）
3. 确认 SDK 已下载：`File → Settings → SDK`（API 12 及以上）
4. 回仓库根跑 `build-harmony.bat`；要发布就跑 `build-harmony.bat release`

## 已知未验证点（本机没有鸿蒙 SDK，只做了静态检查）


1. **面板 API**：`inputMethodEngine.createPanel(context, { type: PanelType.SOFT_KEYBOARD, flag: PanelFlag.FLAG_FIXED })` 与 `panel.setUiContent(...)` 按官方《实现一个输入法应用》与《@ohos.inputMethod.Panel》写的；若 DevEco 报类型错，改 `KeyboardController.ets` 里那一处即可。
2. **面板高度**：页面根节点写死 `PANEL_HEIGHT_VP = 300`（`InputMethodExtensionAbility/pages/Index.ets`）。真机上若键盘区域偏大/偏小，可用 `panel.resize(width, height)`（单位 px，屏宽可用 `display.getDefaultDisplaySync().width`）。
3. **剪贴板权限**：`READ_PASTEBOARD` 是受限权限（需要 ACL）。如果签名 profile 里没带上，`requestPermissionsFromUser` 会直接报错 —— 设置页会把错误码显示出来，便于判断。
4. **preferences 沙箱**：官方文档提到 Extension 可能以独立进程/沙箱运行。若真机上设置页读不到输入法收集的历史，就改成用 DataShare / 统一数据对象在 Extension 与 UIAbility 之间共享。
