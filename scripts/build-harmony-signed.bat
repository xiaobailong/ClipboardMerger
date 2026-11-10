@echo off
chcp 65001 > nul

REM 先切到项目根目录（scripts 的上一级），避免日志写到 scripts\build\logs\
cd /d "%~dp0.." 2>nul || (
    echo [错误] 无法进入项目根目录
    exit /b 1
)

REM ==== 日志初始化（tee 链路同 build.bat / build-harmony.bat，见 ADR-010）====
if not defined _CM_LOG_ACTIVE goto :init_log
goto :skip_log

:init_log
set "_CM_LOG_ACTIVE=1"
if not exist "build\logs" mkdir "build\logs"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "_CM_LOG_TS=%%i"
set "_CM_HLOG=build\logs\harmony_signed_%_CM_LOG_TS%.log"
set "_CM_TEE=%~dp0tools\tee-log.ps1"
set "_CM_SELF=%~f0"
set "_CM_ARGS=%*"
echo 鸿蒙发布签名出包（日志实时双写），日志文件: %_CM_HLOG%
if not exist "%_CM_TEE%" goto :log_legacy
powershell -NoProfile -ExecutionPolicy Bypass -File "%_CM_TEE%" -Log "%_CM_HLOG%"
set _CM_BUILD_RESULT=%ERRORLEVEL%
goto :log_done

:log_legacy
echo [警告] 缺少 tools\tee-log.ps1，退回“先写文件、结束再回显”模式
powershell -NoProfile -Command "[System.IO.File]::WriteAllText('%_CM_HLOG%', '[%_CM_LOG_TS%] 剪集 HarmonyOS Signed Build Start', [System.Text.UTF8Encoding]::new($true))"
call "%~f0" %* 1>> "%_CM_HLOG%" 2>&1
set _CM_BUILD_RESULT=%ERRORLEVEL%
type "%_CM_HLOG%"

:log_done
echo ----------------------------------------
echo 日志已保存: %_CM_HLOG%
echo ----------------------------------------
if defined _CM_NO_PAUSE exit /b %_CM_BUILD_RESULT%
timeout /t 10 > nul
exit /b %_CM_BUILD_RESULT%

:skip_log

title 剪集 HarmonyOS 发布签名出包

REM ============================================
REM  剪集 鸿蒙「发布签名」出包脚本（HAP + .app；只有 .hap 会通过 gh 上传）
REM
REM  用法: build-harmony-signed.bat          增量出包
REM        build-harmony-signed.bat clean    先清 harmony 构建产物，再全量出包
REM        build-harmony-signed.bat publish  出包后把 .hap 上传到 GitHub Release（.app 仅本地）
REM        build-harmony-signed.bat help     显示帮助
REM
REM  签名来源: %SIGN_DIR% 下的 .p12 / .cer / .p7b
REM            （密钥别名与加密口令在 harmony\build-profile.json5 的 signingConfigs 里，
REM              本脚本不保存任何明文口令）
REM  产物: build\harmony\JianJi-HarmonyOS-v<版本>-<build>-release.hap   ← gh 只传这个
REM        build\harmony\JianJi-HarmonyOS-v<版本>-<build>-release.app   ← 仅本地
REM        <仓库根>\JianJi-HarmonyOS-v<版本>-<build>-release.app        ← 仅本地（已 gitignore）
REM  说明: 默认目录不是 D:\Tools\DevTools\hmos\signature_fabu_pro 时，
REM        先 set "SIGN_DIR=<签名目录>" 再运行
REM ============================================

set "HARMONY_DIR=%~dp0..\harmony"
set "HAP_OUT=%~dp0..\build\harmony"
set "VER_TOOL=%~dp0tools\harmony-version.js"
set "BUILD_INFO=%~dp0tools\build-info.js"
set "BUILD_PROFILE=%HARMONY_DIR%\build-profile.json5"
REM 规范化路径（否则日志里会打印 scripts\..\build\harmony 这种带 .. 的形式）
for %%i in ("%HARMONY_DIR%") do set "HARMONY_DIR=%%~fi"
for %%i in ("%HAP_OUT%") do set "HAP_OUT=%%~fi"
for %%i in ("%BUILD_PROFILE%") do set "BUILD_PROFILE=%%~fi"
if not defined SIGN_DIR set "SIGN_DIR=D:\Tools\DevTools\hmos\signature_fabu_pro"
set "_CM_DO_CLEAN="
set "_CM_DO_PUBLISH="
set "GH_EXE=C:\Program Files\GitHub CLI\gh.exe"
set "GH_REPO=xiaobailong/ClipboardMerger"

if /i "%~1"=="help" goto :usage
if /i "%~1"=="-h"   goto :usage
if /i "%~1"=="/?"   goto :usage
if /i "%~1"=="clean"   set "_CM_DO_CLEAN=1"
if /i "%~1"=="publish" set "_CM_DO_PUBLISH=1"

goto :main

:usage
echo.
echo 用法:
echo   build-harmony-signed.bat          增量出包（release 模式 + 发布签名，出 HAP + .app）
echo   build-harmony-signed.bat clean    先清 harmony 构建产物，再全量出包
echo   build-harmony-signed.bat publish  出包后只把 .hap 上传到 GitHub Release（.app 仅本地）
echo   build-harmony-signed.bat help     显示本帮助
echo.
echo 签名目录: %SIGN_DIR%（可 set "SIGN_DIR=..." 覆盖）
echo 产物目录: build\harmony（.app 另拷一份到仓库根）
echo .app 已 gitignore：不会进 git，也不会被 gh 上传；gh 只上传 .hap。
echo 本脚本不做 git commit / push / tag。
echo.
if defined _CM_NO_PAUSE exit /b 0
pause
exit /b 0

:main

echo.
echo ============================================
echo  剪集 鸿蒙发布签名出包
echo ============================================
echo  签名目录: %SIGN_DIR%
echo  构建模式: release（assembleHap）
echo.

if not defined _CM_DO_CLEAN goto :after_clean
echo [0/7] 清理 harmony 构建产物...
for %%d in ("%HARMONY_DIR%\.hvigor" "%HARMONY_DIR%\build" "%HARMONY_DIR%\entry\build") do (
    if exist "%%~d" rmdir /s /q "%%~d" 2>nul
)
echo       完成。
:after_clean

echo.
echo ============================================
echo  [1/7] 检查签名材料与签名配置
echo ============================================
if not exist "%SIGN_DIR%" (
    echo [错误] 签名目录不存在: %SIGN_DIR%
    echo        默认路径不同就先执行: set "SIGN_DIR=<你的签名目录>" 再重跑本脚本
    exit /b 1
)

set "SIGN_P12="
set "SIGN_CER="
set "SIGN_P7B="
for %%f in ("%SIGN_DIR%\*.p12") do if not defined SIGN_P12 set "SIGN_P12=%%~ff"
for %%f in ("%SIGN_DIR%\*.cer") do if not defined SIGN_CER set "SIGN_CER=%%~ff"
for %%f in ("%SIGN_DIR%\*.p7b") do if not defined SIGN_P7B set "SIGN_P7B=%%~ff"

if not defined SIGN_P12 (
    echo [错误] 签名目录里没有 .p12 密钥库: %SIGN_DIR%
    exit /b 1
)
if not defined SIGN_CER (
    echo [错误] 签名目录里没有 .cer 证书: %SIGN_DIR%
    exit /b 1
)
if not defined SIGN_P7B (
    echo [错误] 签名目录里没有 .p7b Profile: %SIGN_DIR%
    exit /b 1
)
echo       密钥库 : %SIGN_P12%
echo       Profile: %SIGN_P7B%
echo       证书   : %SIGN_CER%

if not exist "%BUILD_PROFILE%" (
    echo [错误] 找不到签名配置: %BUILD_PROFILE%
    exit /b 1
)
findstr /c:"signingConfig" "%BUILD_PROFILE%" >nul
if errorlevel 1 (
    echo [错误] build-profile.json5 里没有 signingConfigs / signingConfig ⇒ 只会出 unsigned 包（PIT-037）
    exit /b 1
)
for %%a in ("%SIGN_P12%") do set "SIGN_P12_NAME=%%~nxa"
findstr /c:"%SIGN_P12_NAME%" "%BUILD_PROFILE%" >nul
if errorlevel 1 (
    echo [警告] build-profile.json5 未引用 %SIGN_P12_NAME%
    echo        若签名目录换过，请同步修改 harmony\build-profile.json5 的 signingConfigs
)
echo       签名配置已就绪。

echo.
echo ============================================
echo  [2/7] 定位鸿蒙工具链（hvigor / node / SDK）
echo ============================================
call :locate
if errorlevel 1 exit /b 1
echo       DEVECO_HOME = %DEVECO_HOME%
echo       SDK         = %DEVECO_SDK_HOME%

echo.
echo ============================================
echo  [3/7] 注入构建信息（build-info.js release）
echo ============================================
if not exist "%BUILD_INFO%" (
    echo [警告] 缺少 %BUILD_INFO%，跳过构建信息注入
) else (
    node "%BUILD_INFO%" release
    if errorlevel 1 (
        echo [错误] 构建信息注入失败（见 ISSUE-013）
        exit /b 1
    )
)

echo.
echo ============================================
echo  [4/7] hvigorw assembleHap（release + 发布签名）
echo ============================================
pushd "%HARMONY_DIR%"
if exist "%HARMONY_DIR%\hvigorw.bat" (
    call "%HARMONY_DIR%\hvigorw.bat" assembleHap --mode module -p product=default -p buildMode=release --no-daemon
) else (
    call "%HVIGORW%" assembleHap --mode module -p product=default -p buildMode=release --no-daemon
)
if errorlevel 1 (
    popd
    echo.
    echo [错误] hvigorw 构建失败（完整日志: %_CM_HLOG%）
    echo        常见原因: SDK 未下载 / 签名配置错误 / ArkTS 编译错误
    exit /b 1
)
popd

echo.
echo ============================================
echo  [5/7] 收集 HAP
echo ============================================
set "H_VNAME="
set "H_VCODE="
for /f %%i in ('node "%VER_TOOL%" name') do set "H_VNAME=%%i"
for /f %%i in ('node "%VER_TOOL%" code') do set "H_VCODE=%%i"
if not defined H_VNAME set "H_VNAME=unknown"
if not defined H_VCODE set "H_VCODE=0"
echo       鸿蒙版本: v%H_VNAME% (build %H_VCODE%)

set "HAP_FILE="
set "HAP_UNSIGNED="
REM /o-d = 按修改时间新→旧：取最新的已签名 HAP，避免捡到上一次的旧产物
for /f "delims=" %%f in ('dir /b /s /o-d "%HARMONY_DIR%\entry\build\*.hap" 2^>nul') do (
    if not defined HAP_FILE (
        echo %%f | findstr /i "unsigned" >nul
        if errorlevel 1 (set "HAP_FILE=%%f") else (if not defined HAP_UNSIGNED set "HAP_UNSIGNED=%%f")
    )
)
if defined HAP_FILE goto :hap_ready
echo [错误] 没找到已签名 HAP（签名没打上）
echo        检查 harmony\build-profile.json5: products[].signingConfig 必须是 "default"（PIT-037）
if defined HAP_UNSIGNED echo        当前只有未签名产物: %HAP_UNSIGNED%
exit /b 1

:hap_ready
if not exist "%HAP_OUT%" mkdir "%HAP_OUT%"
set "HAP_NAME=JianJi-HarmonyOS-v%H_VNAME%-%H_VCODE%-release.hap"
copy /y "%HAP_FILE%" "%HAP_OUT%\%HAP_NAME%" >nul
if errorlevel 1 (
    echo [错误] 复制产物失败: %HAP_OUT%\%HAP_NAME%
    exit /b 1
)
echo       原始产物: %HAP_FILE%
echo       已复制到: %HAP_OUT%\%HAP_NAME%

echo.
echo ============================================
echo  [6/7] hvigorw assembleApp（release 模式 .app 包）
echo ============================================
pushd "%HARMONY_DIR%"
if exist "%HARMONY_DIR%\hvigorw.bat" (
    call "%HARMONY_DIR%\hvigorw.bat" assembleApp --mode project -p product=default -p buildMode=release --no-daemon
) else (
    call "%HVIGORW%" assembleApp --mode project -p product=default -p buildMode=release --no-daemon
)
if errorlevel 1 (
    popd
    echo.
    echo [错误] assembleApp 失败（完整日志: %_CM_HLOG%）
    exit /b 1
)
popd

set "APP_FILE="
set "APP_UNSIGNED="
REM /o-d = 按修改时间新→旧：取最新的已签名 .app
for /f "delims=" %%f in ('dir /b /s /o-d "%HARMONY_DIR%\build\outputs\*.app" 2^>nul') do (
    if not defined APP_FILE (
        echo %%f | findstr /i "unsigned" >nul
        if errorlevel 1 (set "APP_FILE=%%f") else (if not defined APP_UNSIGNED set "APP_UNSIGNED=%%f")
    )
)
if defined APP_FILE goto :app_ready
echo [错误] 没找到已签名 .app 包
echo        检查 harmony\build-profile.json5 的 signingConfigs（PIT-037）
if defined APP_UNSIGNED echo        当前只有未签名产物: %APP_UNSIGNED%
exit /b 1

:app_ready
set "APP_NAME=JianJi-HarmonyOS-v%H_VNAME%-%H_VCODE%-release.app"
copy /y "%APP_FILE%" "%HAP_OUT%\%APP_NAME%" >nul
if errorlevel 1 (
    echo [错误] 复制产物失败: %HAP_OUT%\%APP_NAME%
    exit /b 1
)
REM 额外要求：仓库根再放一份带版本号的 .app（文件名含 v<version>-<build>）
set "APP_ROOT=%CD%\%APP_NAME%"
copy /y "%APP_FILE%" "%APP_ROOT%" >nul
if errorlevel 1 (
    echo [错误] 复制到仓库根失败: %APP_ROOT%
    exit /b 1
)
echo       原始产物  : %APP_FILE%
echo       产品目录  : %HAP_OUT%\%APP_NAME%
echo       仓库根副本: %APP_ROOT%

echo.
echo ============================================
echo  [7/7] 校验签名（hap-sign-tool verify-app）
echo ============================================
set "SIGN_TOOL="
if exist "%DEVECO_SDK_HOME%\default\openharmony\toolchains\lib\hap-sign-tool.jar" set "SIGN_TOOL=%DEVECO_SDK_HOME%\default\openharmony\toolchains\lib\hap-sign-tool.jar"
if not defined SIGN_TOOL for /f "delims=" %%j in ('dir /b /s "%DEVECO_SDK_HOME%\hap-sign-tool.jar" 2^>nul') do if not defined SIGN_TOOL set "SIGN_TOOL=%%j"
if not defined SIGN_TOOL (
    echo [警告] 没找到 hap-sign-tool.jar，跳过签名校验
    goto :summary
)

set "JAVA_EXE=java"
if defined JAVA_HOME if exist "%JAVA_HOME%\bin\java.exe" set "JAVA_EXE=%JAVA_HOME%\bin\java.exe"
if /i not "%JAVA_EXE%"=="java" goto :have_java
where java >nul 2>&1
if errorlevel 1 (
    echo [警告] 没找到 java（签名校验需要 JDK），跳过签名校验
    goto :summary
)
:have_java
if not exist "tmp" mkdir "tmp"
call :verify_one "hap" "%HAP_FILE%" "release"
if errorlevel 1 exit /b 1
call :verify_one "app" "%APP_FILE%" ""
if errorlevel 1 exit /b 1
del /q "tmp\verify_hap.cer" "tmp\verify_hap.p7b" "tmp\verify_hap.log" "tmp\verify_app.cer" "tmp\verify_app.p7b" "tmp\verify_app.log" 2>nul

:summary
echo.
echo ============================================
echo  出包完成（发布签名）
echo ============================================
echo  版本   : v%H_VNAME% (build %H_VCODE%)
echo  HAP    : %HAP_OUT%\%HAP_NAME%
echo  APP    : %HAP_OUT%\%APP_NAME%
echo  根目录 : %APP_ROOT%
set "HAP_SHA="
for /f "usebackq delims=" %%h in (`powershell -NoProfile -Command "(Get-FileHash -LiteralPath '%HAP_OUT%\%HAP_NAME%' -Algorithm SHA256).Hash"`) do set "HAP_SHA=%%h"
if defined HAP_SHA echo  HAP SHA256 : %HAP_SHA%
set "APP_SHA="
for /f "usebackq delims=" %%h in (`powershell -NoProfile -Command "(Get-FileHash -LiteralPath '%APP_ROOT%' -Algorithm SHA256).Hash"`) do set "APP_SHA=%%h"
if defined APP_SHA echo  APP SHA256 : %APP_SHA%
echo  装机   : scripts\deploy-harmony.bat "build\harmony\%HAP_NAME%"
echo.
echo  注意: release profile 只能安装在 AGC 允许的设备上；本脚本不做 git commit/push/tag。
echo ============================================
if not defined _CM_DO_PUBLISH goto :summary_done
call :publish_hap
if errorlevel 1 exit /b 1
:summary_done
call :countdown
exit /b 0

REM ============================================
REM  发布到 GitHub Release：只上传 .hap（.app 仅本地，永不入 git / 不上 Release）
REM  用法: build-harmony-signed.bat publish
REM ============================================
:publish_hap
echo.
echo ============================================
echo  上传 GitHub Release（只传 .hap）
echo ============================================
if not exist "%GH_EXE%" (
    echo [错误] 未找到 GitHub CLI: %GH_EXE%
    echo        安装: winget install --id GitHub.cli
    exit /b 1
)
"%GH_EXE%" --version >nul 2>&1
if errorlevel 1 (
    echo [错误] gh 无法执行，请检查安装或路径
    exit /b 1
)
"%GH_EXE%" auth status >nul 2>&1
if errorlevel 1 echo [警告] gh 登录自检未通过（网络瞬断也会导致），继续尝试上传

set "TAG=harmony-v%H_VNAME%"
set "_CM_DIRTY="
for /f "delims=" %%s in ('git status --porcelain 2^>nul') do set "_CM_DIRTY=1"
if defined _CM_DIRTY echo [提示] 工作区有未提交改动：Release 的 tag 指向远端 HEAD，不含本地未提交内容。

echo       标签   : %TAG%
echo       仓库   : %GH_REPO%
echo       上传   : %HAP_NAME%
echo       不上传 : %APP_NAME%（.app 仅本地）

"%GH_EXE%" release view "%TAG%" --repo "%GH_REPO%" >nul 2>&1
if errorlevel 1 (
    "%GH_EXE%" release create "%TAG%" "%HAP_OUT%\%HAP_NAME%" --title "%TAG%" --notes "剪集 鸿蒙版 %TAG%（build %H_VCODE%，发布签名）" --repo "%GH_REPO%"
) else (
    "%GH_EXE%" release edit "%TAG%" --title "%TAG%" --notes "剪集 鸿蒙版 %TAG%（build %H_VCODE%，发布签名）" --repo "%GH_REPO%" >nul 2>&1
    "%GH_EXE%" release upload "%TAG%" "%HAP_OUT%\%HAP_NAME%" --clobber --repo "%GH_REPO%"
)
if errorlevel 1 (
    echo [错误] gh 发布失败（检查 gh auth status / 网络 / 标签 %TAG%）
    exit /b 1
)
echo       Release 链接:
"%GH_EXE%" release view "%TAG%" --repo "%GH_REPO%" --json url --template "{{.url}}"
echo.
echo       Release 附件（只应有 .hap）:
"%GH_EXE%" release view "%TAG%" --repo "%GH_REPO%" --json assets --jq ".[].name"
exit /b 0

REM ============================================
REM  校验单个产物签名（%1=标签 hap/app，%2=文件，%3=期望 profile 类型，可空）
REM ============================================
:verify_one
set "_CM_TAG=%~1"
set "_CM_FILE=%~2"
set "_CM_EXPECT=%~3"
echo --- 校验 %_CM_TAG%: %_CM_FILE%
if not exist "%_CM_FILE%" (
    echo [警告] 文件不存在，跳过校验
    exit /b 0
)
"%JAVA_EXE%" -jar "%SIGN_TOOL%" verify-app -inFile "%_CM_FILE%" -outCertChain "tmp\verify_%_CM_TAG%.cer" -outProfile "tmp\verify_%_CM_TAG%.p7b" > "tmp\verify_%_CM_TAG%.log" 2>&1
set "_CM_VERIFY_RC=%ERRORLEVEL%"
type "tmp\verify_%_CM_TAG%.log"
if not "%_CM_VERIFY_RC%"=="0" (
    echo [错误] %_CM_TAG% 签名校验失败（rc=%_CM_VERIFY_RC%）
    exit /b 1
)
findstr /c:"verify-app success" "tmp\verify_%_CM_TAG%.log" >nul
if errorlevel 1 (
    echo [错误] %_CM_TAG% 校验输出里没有 “verify-app success”
    exit /b 1
)
if "%_CM_EXPECT%"=="" (
    echo       %_CM_TAG%: 签名校验通过 ✓
    exit /b 0
)
findstr /c:"profile type is: %_CM_EXPECT%" "tmp\verify_%_CM_TAG%.log" >nul
if errorlevel 1 (
    echo [警告] %_CM_TAG% 的 Profile 类型不是 %_CM_EXPECT% —— 请确认 build-profile.json5 用的是 release 版 .p7b
) else (
    echo       %_CM_TAG%: Profile 类型 %_CM_EXPECT% ✓
)
exit /b 0

REM ============================================
REM  定位 DevEco Studio / 命令行工具（hvigor / node / SDK）
REM ============================================
:locate
if defined DEVECO_HOME goto :locate_done
if not defined HOS_CLT set "HOS_CLT=D:\Tools\DevTools\hmos\command-line-tools"
if exist "%HOS_CLT%\bin\hvigorw.bat" set "DEVECO_HOME=%HOS_CLT%"
if defined DEVECO_HOME goto :locate_done
if exist "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" set "DEVECO_HOME=C:\Program Files\Huawei\DevEco Studio"
if not defined DEVECO_HOME if exist "D:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" set "DEVECO_HOME=D:\Huawei\DevEco Studio"
if not defined DEVECO_HOME if exist "E:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" set "DEVECO_HOME=E:\Huawei\DevEco Studio"
if not defined DEVECO_HOME if exist "D:\Tools\DevTools\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" set "DEVECO_HOME=D:\Tools\DevTools\Huawei\DevEco Studio"
if not defined DEVECO_HOME if exist "%LOCALAPPDATA%\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" set "DEVECO_HOME=%LOCALAPPDATA%\Huawei\DevEco Studio"
if not defined DEVECO_HOME goto :no_deveco

:locate_done
set "HVIGORW="
if exist "%DEVECO_HOME%\bin\hvigorw.bat" set "HVIGORW=%DEVECO_HOME%\bin\hvigorw.bat"
if not defined HVIGORW if exist "%DEVECO_HOME%\tools\hvigor\bin\hvigorw.bat" set "HVIGORW=%DEVECO_HOME%\tools\hvigor\bin\hvigorw.bat"
if not defined HVIGORW if exist "%HARMONY_DIR%\hvigorw.bat" set "HVIGORW=%HARMONY_DIR%\hvigorw.bat"
if not defined HVIGORW goto :no_hvigorw
set "DEVECO_SDK_HOME=%DEVECO_HOME%\sdk"
set "PATH=%DEVECO_HOME%\tool\node;%DEVECO_HOME%\tools\node;%PATH%"
if exist "D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle\bin\java.exe" set "JAVA_HOME=D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle"
if defined JAVA_HOME set "PATH=%JAVA_HOME%\bin;%PATH%"
if not exist "%DEVECO_HOME%\sdk" echo [警告] 没看到 %DEVECO_HOME%\sdk（SDK 可能装在别处，可在 DevEco 里 File ^> Settings ^> SDK 查看）
exit /b 0

:no_deveco
echo.
echo ============================================
echo  [错误] 没找到 DevEco Studio / 命令行工具
echo ============================================
echo   期望位置: %HOS_CLT%\bin\hvigorw.bat
echo             ^<DevEco^>\tools\hvigor\bin\hvigorw.bat
echo   可先 set "DEVECO_HOME=<工具链目录>" 再重跑本脚本。
exit /b 1

:no_hvigorw
echo.
echo ============================================
echo  [错误] 找不到 hvigorw.bat
echo ============================================
echo   已定位 DEVECO_HOME=%DEVECO_HOME%，但里面没有 bin\hvigorw.bat 或 tools\hvigor\bin\hvigorw.bat
exit /b 1

REM ============================================
REM  倒计时关闭窗口（自动化/CI 时设 _CM_NO_PAUSE=1 跳过）
REM ============================================
:countdown
if defined _CM_NO_PAUSE goto :eof
echo.
echo 所有步骤已完成，窗口将在 60 秒后自动关闭，按任意键立即关闭...
timeout /t 60
goto :eof
