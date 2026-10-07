@echo off
chcp 65001 > nul

REM ==== 日志初始化（tee 链路同 build-harmony.bat，见 ADR-010）====
if not defined _CM_LOG_ACTIVE goto :init_log
goto :skip_log

:init_log
set "_CM_LOG_ACTIVE=1"
if not exist "build\logs" mkdir "build\logs"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "_CM_LOG_TS=%%i"
set "_CM_DLOG=build\logs\deploy_%_CM_LOG_TS%.log"
set "_CM_TEE=%~dp0tools\tee-log.ps1"
set "_CM_SELF=%~f0"
set "_CM_ARGS=%*"
echo 剪集 鸿蒙版装机（hdc 调试通道），日志文件: %_CM_DLOG%
if not exist "%_CM_TEE%" goto :log_legacy
powershell -NoProfile -ExecutionPolicy Bypass -File "%_CM_TEE%" -Log "%_CM_DLOG%"
set _CM_DEPLOY_RESULT=%ERRORLEVEL%
goto :log_done

:log_legacy
echo [警告] 缺少 tools\tee-log.ps1，退回“先写文件、结束再回显”模式
powershell -NoProfile -Command "[System.IO.File]::WriteAllText('%_CM_DLOG%', '[%_CM_LOG_TS%] 剪集 HarmonyOS Deploy Start', [System.Text.UTF8Encoding]::new($true))"
call "%~f0" %* 1>> "%_CM_DLOG%" 2>&1
set _CM_DEPLOY_RESULT=%ERRORLEVEL%
type "%_CM_DLOG%"

:log_done
echo ----------------------------------------
echo 日志已保存: %_CM_DLOG%
echo ----------------------------------------
timeout /t 10 > nul
exit /b %_CM_DEPLOY_RESULT%

:skip_log

title 剪集 HarmonyOS 装机（hdc）
set "BUNDLE=com.example.clipboardmerger"
set "ENTRY_ABILITY=EntryAbility"
set "HAP_DEFAULT=%~dp0harmony\entry\build\default\outputs\default\entry-default-signed.hap"
set "TMPDIR=%~dp0tmp"

cd /d "%~dp0" 2>nul || (
    echo [错误] 无法进入脚本所在目录
    exit /b 1
)

echo.
echo ============================================
echo  剪集 鸿蒙版装机（调试通道 hdc）
echo  用法:
echo    deploy-harmony.bat           装最新构建的签名 HAP + 重启剪集 + 校验版本
echo    deploy-harmony.bat list      只列已连接设备
echo    deploy-harmony.bat 路径.hap  装指定的 HAP（同样会重启 + 校验）
echo  本脚本不碰 git（提交/推送/Release 仍只由 build.bat / build-harmony.bat 负责）
echo ============================================

REM ---- 1) 找 hdc ----
call :find_hdc
if not defined HDC (
    echo [错误] 找不到 hdc.exe
    echo        华为 command-line-tools 默认位置: D:\Tools\DevTools\hmos\command-line-tools
    echo        也可先 set "HOS_CLT=工具链目录" 或 set "DEVECO_HOME=DevEco安装目录"
    echo ===DONE===
    exit /b 1
)
echo [1/5] hdc = %HDC%

REM ---- 2) 设备 ----
set "DEV="
for /f "delims=" %%i in ('"%HDC%" list targets 2^>nul') do set "DEV=%%i"
echo       设备: %DEV%
if "%DEV%"=="" goto :no_device
echo %DEV% | findstr /i "Empty" > nul
if not errorlevel 1 goto :no_device
echo %DEV% | findstr /i "Unauthorized" > nul
if not errorlevel 1 goto :unauth

if /i "%~1"=="list" (
    echo [OK] 设备已连接且已授权
    echo ===DONE===
    exit /b 0
)

REM ---- 3) 选 HAP ----
set "HAP=%HAP_DEFAULT%"
if not "%~1"=="" set "HAP=%~f1"
if not exist "%HAP%" (
    echo [错误] 找不到 HAP: %HAP%
    echo        先跑 build-harmony.bat 出包，或用 deploy-harmony.bat 路径.hap 指定
    echo ===DONE===
    exit /b 1
)
echo [2/5] HAP = %HAP%

if not exist "%TMPDIR%" mkdir "%TMPDIR%"

REM ---- 4) 安装（-r 保留数据：GitHub token / 历史 / 设置都不会丢）----
"%HDC%" install -r "%HAP%" > "%TMPDIR%\deploy_install.txt" 2>&1
type "%TMPDIR%\deploy_install.txt"
findstr /c:"install bundle successfully" "%TMPDIR%\deploy_install.txt" > nul
if errorlevel 1 (
    echo [错误] 装机没成功（日志里没有 install bundle successfully）—— 别当装上了（PIT-044）
    echo        若报 code:9568276 install already exist: 先 "%HDC%" uninstall %BUNDLE% 再装（会丢数据）
    echo ===DONE===
    exit /b 1
)
echo [3/5] 装机成功

REM ---- 5) 重启剪集进程（改输入法代码不 force-stop 会跑旧代码，PIT-040）+ 校验 + 拉起 ----
"%HDC%" shell aa force-stop %BUNDLE% > "%TMPDIR%\deploy_fs.txt" 2>&1
type "%TMPDIR%\deploy_fs.txt"
echo [4/5] 已 force-stop（下次打开即新代码）

set "VER_NAME="
for /f "delims=" %%v in ('node "%~dp0tools\harmony-version.js" name 2^>nul') do set "VER_NAME=%%v"
"%HDC%" shell bm dump -n %BUNDLE% > "%TMPDIR%\deploy_bmdump.txt" 2>&1
if "%VER_NAME%"=="" (
    echo [警告] 读不到 tools\harmony-version.js 的 versionName，跳过版本校验
) else (
    findstr /c:"versionName" "%TMPDIR%\deploy_bmdump.txt" | findstr /c:"%VER_NAME%" > nul
    if errorlevel 1 (
        echo [警告] 设备上的 versionName 与 app.json5 里的 %VER_NAME% 不一致，可能装的是旧包（PIT-029）
        findstr /c:"versionName" /c:"versionCode" "%TMPDIR%\deploy_bmdump.txt"
    ) else (
        echo [5/5] 版本校验 OK: versionName = %VER_NAME%
    )
)

"%HDC%" shell aa start -a %ENTRY_ABILITY% -b %BUNDLE% > "%TMPDIR%\deploy_start.txt" 2>&1
type "%TMPDIR%\deploy_start.txt"
findstr /c:"10106102" "%TMPDIR%\deploy_start.txt" > nul
if not errorlevel 1 (
    echo [提示] 手机锁屏中，App 没被拉起（解锁后手动打开一次即可；开发者模式下系统不允许自动解锁）
) else (
    findstr /c:"successfully" "%TMPDIR%\deploy_start.txt" > nul
    if not errorlevel 1 echo        已拉起 App
)

echo.
echo 诊断输出: %TMPDIR%\deploy_*.txt（可删）
echo ===DONE===
exit /b 0

:no_device
echo [错误] 没有检测到设备（hdc list targets 为空 / Empty）
echo        检查: ①USB 线已连接 ②手机「设置 → 系统 → 开发者选项 → USB 调试」已开
echo              ③手机上是否弹出「允许调试」并点了允许
echo ===DONE===
exit /b 1

:unauth
echo [错误] 设备未授权（Unauthorized）
echo        手机不弹授权框时，换掉本机 hdc 密钥再重连（PIT-045）:
echo          ren "%USERPROFILE%\.harmony\hdckey" hdckey.bak
echo          ren "%USERPROFILE%\.harmony\hdckey.pub" hdckey.pub.bak
echo          "%HDC%" kill
echo          "%HDC%" list targets
echo ===DONE===
exit /b 1

REM ---- 依次找 hdc：命令行工具链 → DevEco Studio → PATH ----
:find_hdc
set "HDC="
if not defined HOS_CLT set "HOS_CLT=D:\Tools\DevTools\hmos\command-line-tools"
if exist "%HOS_CLT%\sdk\default\openharmony\toolchains\hdc.exe" set "HDC=%HOS_CLT%\sdk\default\openharmony\toolchains\hdc.exe"
if defined HDC exit /b 0
if defined DEVECO_HOME if exist "%DEVECO_HOME%\sdk\default\openharmony\toolchains\hdc.exe" set "HDC=%DEVECO_HOME%\sdk\default\openharmony\toolchains\hdc.exe"
if defined HDC exit /b 0
if exist "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" set "HDC=C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
if defined HDC exit /b 0
if exist "D:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" set "HDC=D:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
if defined HDC exit /b 0
if exist "E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" set "HDC=E:\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
if defined HDC exit /b 0
if exist "D:\Tools\DevTools\Huawei DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" set "HDC=D:\Tools\DevTools\Huawei DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
if defined HDC exit /b 0
if exist "%LOCALAPPDATA%\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" set "HDC=%LOCALAPPDATA%\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
if defined HDC exit /b 0
where hdc > nul 2>nul
if errorlevel 1 exit /b 0
for /f "delims=" %%i in ('where hdc 2^>nul') do set "HDC=%%i"
exit /b 0
