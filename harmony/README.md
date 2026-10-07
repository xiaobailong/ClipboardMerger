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
5. 勾完自动签名**再跑一次** `build-harmony.bat`：签名材料（`harmony\signature\` 下的 `.p12/.cer/.p7b`，已 gitignore）由 hvigor 自动使用，产物从 `entry-default-unsigned.hap` 变成 `entry-default-signed.hap`，收集成 `build\harmony\JianJi-HarmonyOS-<版本>.hap` —— 只有这个包才能 `hdc install` 到真机
   - 说明：日常构建用的是已装好的**命令行工具**（`D:\Tools\DevTools\hmos\command-line-tools`），DevEco 只用来做「自动签名」这一步；DevEco 装在非默认目录时告诉脚本 `set "DEVECO_HOME=<DevEco 目录>"` 也不影响（签名配置在工程里，跟用哪套 hvigor 无关）

## 首次 DevEco 自动签名后：务必检查这一行（实测踩到）

DevEco 26 的「自动签名」只写 `signingConfigs` 数组，**不会**给 product 加引用，于是 hvigor 会打印
`WARN: No signingConfig found for product default`、`SignHap` 秒过、产物仍是 `entry-default-unsigned.hap`（根本装不上真机）。
在 `harmony/build-profile.json5` 的 `products[0]` 里补一行就好了：

```json5
"signingConfig": "default",
```

配套两点：

- 自动签名会把**材料绝对路径 + 加密口令**（`0000001A…`，机器绑定）写回该文件 ⇒ `harmony/build-profile.json5` 已 gitignore；
  仓库里的基线是 **`harmony/build-profile.template.json5`**（新机器：`copy harmony\build-profile.template.json5 harmony\build-profile.json5` 再签名）。
- 装机若报 `failed to install bundle. code:9568276 error: install already exist`：先
  `hdc uninstall com.example.clipboardmerger`，再 `hdc install <hap>`（`-r` 在这台设备上不顶用）。

## 签名材料放哪（证书可复用 / Profile 项目专属）

| 材料 | 放哪 | 能否跨 App 复用 |
| --- | --- | --- |
| 证书 `.cer` + 私钥 `.p12` + 密码 | `D:\Tools\DevTools\hmos\signature\`（**公共证书目录**，本机工具目录，不在任何 git 仓库里） | ✅ 可给多个鸿蒙 App、多个 Profile 复用 |
| **Profile `.p7b`** | `harmony\signature\`（本项目；gitignore 只放行该目录的 `README.md`） | ❌ 绑死包名 `com.example.clipboardmerger` |
| 调试设备 UDID 列表 | 写在 Profile 的 `debug-info.device-ids` 里，在 AGC 维护 | 换手机/加手机要回 AGC 加设备并重新下载 `.p7b` |

公共目录里已经生成好：`hmos-dev.p12`（别名 `hmos-dev`）、`hmos-dev.csr`（待上传 AGC 换证书）、`hmos-dev.pass`（密钥库密码），用法见 `D:\Tools\DevTools\hmos\signature\README.md`。

DevEco「自动签名」会把材料直接写进 `harmony\signature\`，也能用；建议把它的 `.p12/.cer` 拷一份到公共目录，下一个项目就能复用（Profile 仍要按新包名重新申请）。

### 备用：不装 DevEco 的手动签名（参数已用本机 SDK 核实，随时可切）

`OH_TC` = `D:\Tools\DevTools\hmos\command-line-tools\sdk\default\openharmony\toolchains`；`java` 用 `D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle\bin\java.exe`。

```bat
set "JAVA=D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle\bin\java.exe"
set "OH_TC=D:\Tools\DevTools\hmos\command-line-tools\sdk\default\openharmony\toolchains"
set "SHARED=D:\Tools\DevTools\hmos\signature"

REM 1) 公共证书已生成：%SHARED%\hmos-dev.p12（别名 hmos-dev）+ .csr + .pass（密码）
REM    要重来（换密钥/证书过期）就重新 generate-keypair + generate-csr，命令见 %SHARED%\README.md

REM 2) AGC 网页：建项目 + 添加应用（包名 com.example.clipboardmerger）
REM    → 证书管理上传 %SHARED%\hmos-dev.csr 换「调试证书」→ 下载存成 %SHARED%\hmos-dev.cer
REM    → 添加调试设备（UDID: hdc shell bm get --udid）
REM    → Profile 管理建「调试 Profile」→ 下载 .p7b 放到 harmony\signature\

REM 3) 本地签名 + 校验 + 装机（<密码> 见 %SHARED%\hmos-dev.pass）
"%JAVA%" -jar "%OH_TC%\lib\hap-sign-tool.jar" sign-app -mode localSign -keyAlias "hmos-dev" -keyPwd <密码> ^
  -appCertFile "%SHARED%\hmos-dev.cer" -profileFile "harmony\signature\<包名>.p7b" ^
  -inFile "harmony\entry\build\default\outputs\default\entry-default-unsigned.hap" ^
  -signAlg SHA256withECDSA -keystoreFile "%SHARED%\hmos-dev.p12" -keystorePwd <密码> ^
  -outFile "harmony\signature\entry-default-signed.hap" -compatibleVersion 26 -signCode "1"
"%JAVA%" -jar "%OH_TC%\lib\hap-sign-tool.jar" verify-app -inFile "harmony\signature\entry-default-signed.hap" ^
  -outCertChain "harmony\signature\verify.cer" -outProfile "harmony\signature\verify.p7b"
"%OH_TC%\hdc.exe" install "harmony\signature\entry-default-signed.hap"
```

## 已知未验证点（本机没有鸿蒙 SDK，只做了静态检查）


1. **面板 API**：`inputMethodEngine.createPanel(context, { type: PanelType.SOFT_KEYBOARD, flag: PanelFlag.FLAG_FIXED })` 与 `panel.setUiContent(...)` 按官方《实现一个输入法应用》与《@ohos.inputMethod.Panel》写的；若 DevEco 报类型错，改 `KeyboardController.ets` 里那一处即可。
2. **面板高度**：页面根节点写死 `PANEL_HEIGHT_VP = 300`（`InputMethodExtensionAbility/pages/Index.ets`）。真机上若键盘区域偏大/偏小，可用 `panel.resize(width, height)`（单位 px，屏宽可用 `display.getDefaultDisplaySync().width`）。
3. **剪贴板权限**：`READ_PASTEBOARD` 是受限权限（需要 ACL）。如果签名 profile 里没带上，`requestPermissionsFromUser` 会直接报错 —— 设置页会把错误码显示出来，便于判断。
4. **preferences 沙箱**：官方文档提到 Extension 可能以独立进程/沙箱运行。若真机上设置页读不到输入法收集的历史，就改成用 DataShare / 统一数据对象在 Extension 与 UIAbility 之间共享。
