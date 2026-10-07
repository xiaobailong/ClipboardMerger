@echo off
chcp 65001 > nul

REM ==== 日志初始化（tee 链路同 build.bat，见 ADR-010）====
if not defined _CM_LOG_ACTIVE goto :init_log
goto :skip_log

:init_log
set "_CM_LOG_ACTIVE=1"
if not exist "build\logs" mkdir "build\logs"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "_CM_LOG_TS=%%i"
set "_CM_HLOG=build\logs\harmony_%_CM_LOG_TS%.log"
set "_CM_TEE=%~dp0tools\tee-log.ps1"
set "_CM_SELF=%~f0"
set "_CM_ARGS=%*"
echo 鸿蒙包构建（日志实时双写），日志文件: %_CM_HLOG%
if not exist "%_CM_TEE%" goto :log_legacy
REM 逐行 tee：tools\tee-log.ps1 读子进程输出，先写日志文件再回显控制台
powershell -NoProfile -ExecutionPolicy Bypass -File "%_CM_TEE%" -Log "%_CM_HLOG%"
set _CM_BUILD_RESULT=%ERRORLEVEL%
goto :log_done

:log_legacy
echo [警告] 缺少 tools\tee-log.ps1，退回“先写文件、结束再回显”模式
powershell -NoProfile -Command "[System.IO.File]::WriteAllText('%_CM_HLOG%', '[%_CM_LOG_TS%] 剪集 HarmonyOS Build Start', [System.Text.UTF8Encoding]::new($true))"
call "%~f0" %* 1>> "%_CM_HLOG%" 2>&1
set _CM_BUILD_RESULT=%ERRORLEVEL%
type "%_CM_HLOG%"

:log_done
echo ----------------------------------------
echo 日志已保存: %_CM_HLOG%
echo ----------------------------------------
timeout /t 10 > nul
exit /b %_CM_BUILD_RESULT%

:skip_log

title 剪集 HarmonyOS Build

REM ============================================
REM  剪集 鸿蒙包构建脚本（Android 侧仍走 build.bat，两者互不干扰）
REM  用法: build-harmony.bat           只构建（出 HAP，不动 git）
REM        build-harmony.bat release   构建 + 递增版本 + 提交/推送 + tag + GitHub Release
REM        build-harmony.bat clean     清理鸿蒙构建产物
REM  依赖: DevEco Studio（自带 hvigor / node / ohpm / HarmonyOS SDK）
REM        —— 不在默认目录时先 set "DEVECO_HOME=<你的安装目录>"
REM ============================================

set "GH_EXE=C:\Program Files\GitHub CLI\gh.exe"
set "GH_REPO=xiaobailong/ClipboardMerger"
set "HARMONY_DIR=%~dp0harmony"
set "HAP_OUT=%~dp0build\harmony"
set "VER_TOOL=%~dp0tools\harmony-version.js"

cd /d "%~dp0" 2>nul || (
    echo [错误] 无法进入脚本所在目录
    pause
    exit /b 1
)

if not exist "%HARMONY_DIR%\entry" (
    echo [错误] 找不到 harmony\entry —— 本脚本必须在仓库根运行
    pause
    exit /b 1
)

if /i "%~1"=="clean"   goto :clean
if /i "%~1"=="release" goto :release
goto :build

REM ============================================
REM  定位 DevEco Studio（hvigor / node / ohpm / SDK）
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
echo [信息] 工具链: %DEVECO_HOME%
echo [信息] hvigorw: %HVIGORW%
set "DEVECO_SDK_HOME=%DEVECO_HOME%\sdk"
set "PATH=%DEVECO_HOME%\tool\node;%DEVECO_HOME%\tools\node;%PATH%"
if exist "D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle\bin\java.exe" set "JAVA_HOME=D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle"
if defined JAVA_HOME set "PATH=%JAVA_HOME%\bin;%PATH%"
if not exist "%DEVECO_HOME%\sdk" echo [警告] 没看到 %DEVECO_HOME%\sdk（SDK 可能装在别处，可在 DevEco 里 File ^> Settings ^> SDK 查看）
goto :eof

:no_hvigorw
echo.
echo ============================================
echo  [错误] 找不到 hvigorw.bat
echo ============================================
echo   期望位置之一:
echo     DevEco Studio:    ^<安装目录^>\tools\hvigor\bin\hvigorw.bat
echo     命令行工具:       ^<安装目录^>\bin\hvigorw.bat
echo   也可先 set "DEVECO_HOME=你的工具链目录" 再重跑。
pause
exit /b 1
goto :eof

:no_deveco
echo.
echo ============================================
echo  [错误] 没找到 DevEco Studio
echo ============================================
echo   命令行构建必须有 DevEco Studio 自带的 hvigor + HarmonyOS SDK
echo   （hvigor 只在 DevEco 安装包里，公共 npm / 镜像上都没有）。
echo.
echo   下载: https://developer.huawei.com/consumer/cn/download/deveco-studio
echo         安装时不需要改路径；装完在“设置 - SDK”里确认 SDK 已下载。
echo.
echo   若装在自定义目录，请先执行:
echo         set "DEVECO_HOME=你的安装目录"
echo   再重跑本脚本。
pause
exit /b 1

REM ============================================
REM  构建
REM ============================================
:build
call :locate
if errorlevel 1 exit /b 1

echo.
echo ============================================
echo  [1/3] 检查签名配置
echo ============================================
findstr /c:"\"signingConfigs\": []" "%HARMONY_DIR%\build-profile.json5" >nul 2>&1
if not errorlevel 1 echo [警告] signingConfigs 为空：这次只能出未签名 HAP，装不上真机。请先在 DevEco 里 Project Structure ^> Signing Configs 勾选 Automatically generate signature。

echo.
echo ============================================
echo  [2/3] hvigorw assembleHap
echo ============================================
node "%~dp0tools\build-info.js"
pushd "%HARMONY_DIR%"
if exist "%HARMONY_DIR%\hvigorw.bat" (
    call "%HARMONY_DIR%\hvigorw.bat" assembleHap
) else (
    call "%HVIGORW%" assembleHap
)
if errorlevel 1 (
    popd
    echo.
    echo [错误] hvigorw 构建失败（请看上面的报错行；完整日志: %_CM_HLOG%）
    echo        常见原因: SDK 未下载 / 签名未配置 / ArkTS 编译错误
    pause
    exit /b 1
)
popd

echo.
echo ============================================
echo  [3/3] 收集产物
echo ============================================
for /f %%i in ('node "%VER_TOOL%" name') do set "H_VNAME=%%i"
for /f %%i in ('node "%VER_TOOL%" code') do set "H_VCODE=%%i"
echo       鸿蒙版本: v%H_VNAME% (build %H_VCODE%)

set "HAP_FILE="
set "HAP_UNSIGNED="
for /f "delims=" %%f in ('dir /b /s "%HARMONY_DIR%\entry\build\*.hap" 2^>nul') do (
    echo %%f | findstr /i "unsigned" >nul
    if errorlevel 1 (set "HAP_FILE=%%f") else (set "HAP_UNSIGNED=%%f")
)
if not defined HAP_FILE set "HAP_FILE=%HAP_UNSIGNED%"
if not defined HAP_FILE (
    echo [错误] 没找到 .hap 产物（检查 harmony\entry\build\default\outputs）
    pause
    exit /b 1
)
if not exist "%HAP_OUT%" mkdir "%HAP_OUT%"
set "HAP_NAME=JianJi-HarmonyOS-v%H_VNAME%-%H_VCODE%.hap"
copy /y "%HAP_FILE%" "%HAP_OUT%\%HAP_NAME%" >nul
echo       原始产物: %HAP_FILE%
echo       已复制到: %HAP_OUT%\%HAP_NAME%
set "HAP_SIGN_STATE="
echo %HAP_FILE% | findstr /i "unsigned" >nul 2>&1
if not errorlevel 1 set "HAP_SIGN_STATE=（未签名，装真机前需先按 harmony\README.md 配签名）"
if "%HAP_SIGN_STATE%"=="" set "HAP_SIGN_STATE=（已签名）"

echo.
echo ============================================
echo  构建完成
echo  HAP: %HAP_OUT%\%HAP_NAME%
echo ============================================
if defined _CM_RELEASE goto :publish
echo （未推送。需要提交 + tag + Release 时跑: build-harmony.bat release）
call :countdown
exit /b 0

REM ============================================
REM  release: 递增版本 → 构建 → 提交/推送 → tag → GitHub Release
REM ============================================
:release
echo.
echo ============================================
echo  [发布 1/6] 递增鸿蒙版本号
echo ============================================
node "%VER_TOOL%" bump
if errorlevel 1 (
    echo [错误] 版本号递增失败
    pause
    exit /b 1
)
set "_CM_RELEASE=1"
goto :build

REM ============================================
REM  发布：git 提交 / 推送 / tag / gh release
REM ============================================
:publish
echo.
echo ============================================
echo  [发布 2/6] 检查 gh CLI
echo ============================================
call :check_gh
if errorlevel 1 exit /b 1

echo.
echo ============================================
echo  [发布 3/6] git 提交
echo ============================================
git add -A
git commit -m "release(harmony): v%H_VNAME% (build %H_VCODE%)"
if errorlevel 1 echo       [警告] 没有可提交的改动（或提交失败），继续

echo.
echo ============================================
echo  [发布 4/6] 推送分支
echo ============================================
call :git_push HEAD
if errorlevel 1 exit /b 1

set "TAG=harmony-v%H_VNAME%"
echo.
echo ============================================
echo  [发布 5/6] 打 tag 并推送 %TAG%
echo ============================================
git tag -f "%TAG%"
if errorlevel 1 (
    echo [错误] 打 tag 失败: %TAG%
    pause
    exit /b 1
)
call :git_push "%TAG%" force
if errorlevel 1 exit /b 1

echo.
echo ============================================
echo  [发布 6/6] GitHub Release（上传 HAP）
echo ============================================
call :gh_release
if errorlevel 1 exit /b 1

echo.
echo ============================================
echo  发布成功！
echo  版本: %TAG%
echo  HAP:  %HAP_OUT%\%HAP_NAME%
echo ============================================
call :countdown
exit /b 0

REM ============================================
REM  检查 gh CLI（子过程，失败 exit /b 1）
REM ============================================
:check_gh
if not exist "%GH_EXE%" (
    echo [错误] GitHub CLI ^(gh^) 未安装！
    echo        路径: %GH_EXE%
    echo        安装: winget install --id GitHub.cli
    exit /b 1
)
"%GH_EXE%" --version
if errorlevel 1 (
    echo [错误] gh 命令无法执行，请检查安装！
    exit /b 1
)
"%GH_EXE%" auth status >nul 2>&1
if errorlevel 1 (
    echo       [警告] gh 登录状态自检未通过（网络瞬断也会导致），详情如下:
    echo       ----------------------------------------
    "%GH_EXE%" auth status
    echo       ----------------------------------------
    echo       若提示 token 无效，请运行: gh auth login
)
exit /b 0

REM ============================================
REM  推送（子过程）：网络瞬断（Connection reset / timeout）自动重试 3 次
REM  用法: call :git_push HEAD ／ call :git_push "tag" force
REM ============================================
:git_push
set "_CM_PUSH_REF=%~1"
set "_CM_PUSH_FORCE="
if /i "%~2"=="force" set "_CM_PUSH_FORCE=-f"
set "_CM_PUSH_N=0"

:git_push_try
set /a _CM_PUSH_N+=1
if %_CM_PUSH_N%==1 echo       推送 %_CM_PUSH_REF% ...
if %_CM_PUSH_N% gtr 1 echo       [重试 %_CM_PUSH_N%/3] 推送 %_CM_PUSH_REF% ...
call git push origin %_CM_PUSH_REF% %_CM_PUSH_FORCE%
if not errorlevel 1 exit /b 0
if %_CM_PUSH_N% lss 3 (
    echo       [警告] 推送失败，3 秒后重试...
    ping -n 4 127.0.0.1 > nul
    goto :git_push_try
)
echo [错误] git push %_CM_PUSH_REF% 连续 3 次失败！
echo        常见原因: 网络瞬断、代理、22 端口被拦。
echo        手工重试: git push origin %_CM_PUSH_REF%
exit /b 1

REM ============================================
REM  创建 / 覆盖 GitHub Release 并上传 HAP（子过程，可重复执行）
REM  依赖: %GH_EXE% %GH_REPO% %TAG% %H_VCODE% %HAP_OUT% %HAP_NAME%
REM ============================================
:gh_release
if not exist "%HAP_OUT%\%HAP_NAME%" (
    echo [错误] HAP 不存在: %HAP_OUT%\%HAP_NAME%
    exit /b 1
)
"%GH_EXE%" release view "%TAG%" --repo "%GH_REPO%" >nul 2>&1
if errorlevel 1 (
    echo       创建 Release %TAG% 并上传 HAP...
    "%GH_EXE%" release create "%TAG%" "%HAP_OUT%\%HAP_NAME%" --title "%TAG%" --notes "剪集 鸿蒙版 %TAG%（build %H_VCODE%）%HAP_SIGN_STATE%" --repo "%GH_REPO%"
) else (
    echo       Release %TAG% 已存在，更新说明并覆盖上传 HAP...
    "%GH_EXE%" release edit "%TAG%" --title "%TAG%" --notes "剪集 鸿蒙版 %TAG%（build %H_VCODE%）%HAP_SIGN_STATE%" --repo "%GH_REPO%" >nul 2>&1
    "%GH_EXE%" release upload "%TAG%" "%HAP_OUT%\%HAP_NAME%" --clobber --repo "%GH_REPO%"
)
if errorlevel 1 (
    echo [错误] gh 返回失败，请检查: gh auth status / 网络 / 标签 %TAG%
    exit /b 1
)
echo       Release 链接:
"%GH_EXE%" release view "%TAG%" --repo "%GH_REPO%" --json url --template "{{.url}}"
echo.
exit /b 0

REM ============================================
REM  清理鸿蒙构建产物
REM ============================================
:clean
echo.
echo ============================================
echo  清理鸿蒙构建产物...
echo ============================================
if exist "%HARMONY_DIR%\.hvigor" rmdir /s /q "%HARMONY_DIR%\.hvigor" 2>nul
if exist "%HARMONY_DIR%\build" rmdir /s /q "%HARMONY_DIR%\build" 2>nul
if exist "%HARMONY_DIR%\entry\build" rmdir /s /q "%HARMONY_DIR%\entry\build" 2>nul
if exist "%HARMONY_DIR%\oh_modules" rmdir /s /q "%HARMONY_DIR%\oh_modules" 2>nul
if exist "%~dp0build\harmony" rmdir /s /q "%~dp0build\harmony" 2>nul
del /q "%~dp0*.hap" 2>nul
echo       完成。
call :countdown
exit /b 0

REM ============================================
REM  60 秒倒计时关闭窗口
REM ============================================
:countdown
echo.
echo 所有步骤已完成，窗口将在 60 秒后自动关闭，按任意键立即关闭...
timeout /t 60
goto :eof
