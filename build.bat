@echo off
chcp 65001 > nul

REM ==== 日志初始化 ====
if not defined _CM_LOG_ACTIVE goto :init_log
goto :skip_log

:init_log
set "_CM_LOG_ACTIVE=1"
if not exist "build\logs" mkdir "build\logs"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "_CM_LOG_TS=%%i"
set "_CM_LOGFILE=build\logs\build_%_CM_LOG_TS%.log"
set "_CM_TEE=%~dp0tools\tee-log.ps1"
set "_CM_SELF=%~f0"
set "_CM_ARGS=%*"
echo 正在构建（日志实时双写：文件 + 控制台），日志文件: %_CM_LOGFILE%
if not exist "%_CM_TEE%" goto :log_legacy
REM 逐行 tee：tools\tee-log.ps1 读子进程输出，先写日志文件再回显控制台（见 ADR-010）
powershell -NoProfile -ExecutionPolicy Bypass -File "%_CM_TEE%" -Log "%_CM_LOGFILE%"
set _CM_BUILD_RESULT=%ERRORLEVEL%
goto :log_done

:log_legacy
echo [警告] 缺少 tools\tee-log.ps1，退回“先写文件、结束再回显”模式
REM 日志保存为 UTF-8（通过 PowerShell 写入 BOM）
powershell -NoProfile -Command "[System.IO.File]::WriteAllText('%_CM_LOGFILE%', '[%_CM_LOG_TS%] ClipboardMerger Build Start', [System.Text.UTF8Encoding]::new($true))"
call "%~f0" %* 1>> "%_CM_LOGFILE%" 2>&1
set _CM_BUILD_RESULT=%ERRORLEVEL%
type "%_CM_LOGFILE%"

:log_done
echo ----------------------------------------
echo 日志已保存: %_CM_LOGFILE%
echo ----------------------------------------
timeout /t 10 > nul
exit /b %_CM_BUILD_RESULT%

:skip_log

title ClipboardMerger Build

REM ============================================
REM  ClipboardMerger 一键构建脚本
REM  用法: 双击运行        (构建+递增版本+GitHub Release)
REM        build setup     (安装 Android SDK 组件)
REM        build clean     (清理构建产物)
REM        build release   (同双击，构建+Git推送+GitHub Release)
REM ============================================

set "JAVA_HOME=D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle"
set "ANDROID_HOME=D:\Tools\DevTools\Android\Sdk"
set "ANDROID_SDK_ROOT=D:\Tools\DevTools\Android\Sdk"
set "PATH=D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle\bin;D:\Tools\DevTools\gradle\gradle-8.5\bin;%PATH%"
set "GH_EXE=C:\Program Files\GitHub CLI\gh.exe"
set "GH_REPO=xiaobailong/ClipboardMerger"
set "JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8"

cd /d d:\WorkSpace\test\ClipboardMerger 2>nul || (
    echo [错误] 项目目录不存在
    pause
    exit /b 1
)

if not exist "build" mkdir "build"

if /i "%~1"=="setup"   goto :setup
if /i "%~1"=="clean"   goto :clean
if /i "%~1"=="release" goto :release
goto :build

REM ============================================
REM  SDK 组件安装 (一次性)
REM ============================================
:setup
echo.
echo ============================================
echo  正在安装 Android SDK 组件...
echo ============================================
echo.
echo y | "D:\Tools\DevTools\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat" --sdk_root="D:\Tools\DevTools\Android\Sdk" "platforms;android-34" "build-tools;34.0.0" "platform-tools"
if %ERRORLEVEL% neq 0 (
    echo [错误] SDK 安装失败
    pause
    exit /b 1
)
echo.
echo [完成] SDK 安装成功。
call :countdown
exit /b 0

REM ============================================
REM  清理构建产物
REM ============================================
:clean
echo.
echo ============================================
echo  正在清理构建产物...
echo ============================================
echo.
call "D:\Tools\DevTools\gradle\gradle-8.5\bin\gradle.bat" clean --no-daemon --console=plain
rmdir /s /q ".gradle" 2>nul
if exist "*.apk" del /q "*.apk" 2>nul
if exist "*.aab" del /q "*.aab" 2>nul
REM Cline 临时目录：整目录删除（约定见 .clinerules/tmp-files.md）
rmdir /s /q "tmp" 2>nul
echo.
echo [完成] 清理完成。
call :countdown
exit /b 0

REM ============================================
REM  完整构建流程
REM ============================================
:build
echo.
echo ============================================
echo  ClipboardMerger 构建 - %date% %time%
echo ============================================
echo.

echo [1/5] 递增版本号...
call "D:\Tools\DevTools\gradle\gradle-8.5\bin\gradle.bat" incrementVersion --no-daemon --console=plain
if %ERRORLEVEL% neq 0 (
    echo [错误] 版本号递增失败！Exit code=%ERRORLEVEL%
    call :countdown
    exit /b 1
)
echo       完成。

echo [2/5] 清理旧产物...
call "D:\Tools\DevTools\gradle\gradle-8.5\bin\gradle.bat" clean --no-daemon --console=plain
echo       完成。

echo [3/5] 编译 APK（请耐心等待）...
call "D:\Tools\DevTools\gradle\gradle-8.5\bin\gradle.bat" assembleDebug --no-daemon --console=plain
set BUILD_EXIT=%ERRORLEVEL%

echo.
if %BUILD_EXIT% neq 0 (
    echo ============================================
    echo  构建失败！Exit code=%BUILD_EXIT%
    echo ============================================
    call :countdown
    exit /b 1
)

echo ============================================
echo  构建成功！
echo ============================================
if exist "*.apk" del /q "*.apk" 2>nul
set "APK_PATH="
for /f "delims=" %%f in ('dir /s /b build\outputs\apk\debug\*.apk 2^>nul') do (
    copy /y "%%f" "." > nul
    set "APK_PATH=%%f"
    echo  APK: %%~nxf  ^(%%~zf bytes^)
)
if "%APK_PATH%"=="" (
    echo [错误] 未找到 APK 文件！
    call :countdown
    exit /b 1
)
echo.
echo  APK 已复制到项目根目录。
echo.

echo [4/5] 发布到 GitHub Release...
echo.
echo       检查 gh CLI...
call :check_gh
if errorlevel 1 (
    call :countdown
    exit /b 1
)

echo       读取版本信息...
for /f "tokens=2 delims==" %%i in ('findstr "versionName=" version.properties') do set "V_NAME=%%i"
for /f "tokens=2 delims==" %%i in ('findstr "versionCode=" version.properties') do set "V_CODE=%%i"
set "TAG=v%V_NAME%"
echo       版本: %TAG% (code=%V_CODE%)

echo       提交版本变更...
call git add version.properties
call git diff --cached --quiet
if errorlevel 1 (
    call git commit -m "release: %TAG% (build %V_CODE%)"

    echo       推送代码...
    call :git_push main
    if errorlevel 1 (
        echo [错误] git push 失败！
        call :countdown
        exit /b 1
    )

    echo       创建标签 %TAG%...
    call git tag -f -a "%TAG%" -m "Release %TAG% - build %V_CODE%"
    call :git_push "%TAG%"
    if errorlevel 1 (
        echo       [警告] 普通推送标签失败，改用强制推送...
        call :git_push "%TAG%" force
        if errorlevel 1 (
            echo [错误] tag push 失败！
            call :countdown
            exit /b 1
        )
    )

    echo       创建 GitHub Release 并上传 APK...
    call :gh_release
    if errorlevel 1 (
        echo [错误] GitHub Release 发布失败！
        call :countdown
        exit /b 1
    )
) else (
    echo       版本号未变更（已提交），检测推送状态...
    call git diff origin/main..HEAD --quiet
    if errorlevel 1 (
        echo       有未推送的提交，正在推送...
        call :git_push main
        if errorlevel 1 (
            echo [错误] git push 失败！
            call :countdown
            exit /b 1
        )
    ) else (
        echo       已推送，直接创建Release...
    )

    echo       创建/更新标签 %TAG%...
    call git tag -f -a "%TAG%" -m "Release %TAG% - build %V_CODE%" 2>nul
    call :git_push "%TAG%" force
    if errorlevel 1 (
        echo [错误] tag push 失败！
        call :countdown
        exit /b 1
    )

    echo       创建/更新 GitHub Release 并上传 APK...
    call :gh_release
    if errorlevel 1 (
        echo [错误] GitHub Release 发布失败！
        call :countdown
        exit /b 1
    )
)

echo.
echo ============================================
echo  构建 ^& 发布成功！
echo  版本: %TAG%
echo  GitHub Release已创建并上传APK
echo ============================================
call :countdown
exit /b 0

REM ============================================
REM  构建 + Git推送 + GitHub Release
REM ============================================
:release
echo.
echo ============================================
echo  ClipboardMerger 构建 ^& 发布 - %date% %time%
echo ============================================
echo.

echo [1/6] 检查gh CLI...
call :check_gh
if errorlevel 1 (
    pause
    exit /b 1
)

echo [2/6] 检查git状态...
call git diff --quiet
if %ERRORLEVEL% neq 0 (
    echo [警告] 工作区有未提交的更改，请先提交或暂存！
    pause
    exit /b 1
)
echo       工作区干净。

echo [3/6] 递增版本号...
call "D:\Tools\DevTools\gradle\gradle-8.5\bin\gradle.bat" incrementVersion --no-daemon --console=plain
if %ERRORLEVEL% neq 0 (
    echo [错误] 版本号递增失败！
    pause
    exit /b 1
)
echo       完成。

echo [4/6] 读取版本信息...
for /f "tokens=2 delims==" %%i in ('findstr "versionName=" version.properties') do set "V_NAME=%%i"
for /f "tokens=2 delims==" %%i in ('findstr "versionCode=" version.properties') do set "V_CODE=%%i"
set "TAG=v%V_NAME%"
echo       版本: %TAG% (code=%V_CODE%)

echo [5/6] 编译APK...
call "D:\Tools\DevTools\gradle\gradle-8.5\bin\gradle.bat" clean assembleDebug --no-daemon --console=plain
set BUILD_EXIT=%ERRORLEVEL%
if %BUILD_EXIT% neq 0 (
    echo ============================================
    echo  构建失败！Exit code=%BUILD_EXIT%
    echo ============================================
    pause
    exit /b 1
)
echo       构建成功。

set "APK_PATH="
for /f "delims=" %%f in ('dir /s /b build\outputs\apk\debug\*.apk 2^>nul') do set "APK_PATH=%%f"
if "%APK_PATH%"=="" (
    echo [错误] 找不到APK文件！
    pause
    exit /b 1
)
echo       APK: %APK_PATH%

echo [6/6] Git提交并推送 + GitHub Release...
echo.
echo       提交版本变更...
call git add version.properties
call git diff --cached --quiet
if errorlevel 1 (
    call git commit -m "release: %TAG% (build %V_CODE%)"

    echo       推送代码...
    call :git_push main
    if errorlevel 1 (
        echo [错误] git push 失败！
        pause
        exit /b 1
    )

    echo       创建标签 %TAG%...
    call git tag -f -a "%TAG%" -m "Release %TAG% - build %V_CODE%"
    call :git_push "%TAG%"
    if errorlevel 1 (
        echo       [警告] 普通推送标签失败，改用强制推送...
        call :git_push "%TAG%" force
        if errorlevel 1 (
            echo [错误] tag push 失败！
            pause
            exit /b 1
        )
    )

    echo       创建 GitHub Release 并上传 APK...
    call :gh_release
    if errorlevel 1 (
        echo [错误] GitHub Release 发布失败！
        pause
        exit /b 1
    )
) else (
    echo       版本号未变更（已提交），检测推送状态...
    call git diff origin/main..HEAD --quiet
    if errorlevel 1 (
        echo       有未推送的提交，正在推送...
        call :git_push main
        if errorlevel 1 (
            echo [错误] git push 失败！
            pause
            exit /b 1
        )
    ) else (
        echo       已推送，直接创建Release...
    )

    echo       创建/更新标签 %TAG%...
    call git tag -f -a "%TAG%" -m "Release %TAG% - build %V_CODE%" 2>nul
    call :git_push "%TAG%" force
    if errorlevel 1 (
        echo [错误] tag push 失败！
        pause
        exit /b 1
    )

    echo       创建/更新 GitHub Release 并上传 APK...
    call :gh_release
    if errorlevel 1 (
        echo [错误] GitHub Release 发布失败！
        pause
        exit /b 1
    )
)

echo.
echo ============================================
echo  发布成功！
echo  版本: %TAG%
echo  APK:  %APK_PATH%
echo  GitHub Release已创建并上传APK
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
REM  用法: call :git_push main ／ call :git_push "%TAG%" ／ call :git_push "%TAG%" force
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
echo        常见原因: 网络瞬断（Connection reset / timeout）、代理、22 端口被拦。
echo        手工重试:            git push origin %_CM_PUSH_REF%
echo        改走 HTTPS（一次性）: gh auth setup-git ^&^& git remote set-url origin https://github.com/%GH_REPO%.git
exit /b 1

REM ============================================
REM  创建 / 覆盖 GitHub Release 并上传 APK（子过程，可重复执行）
REM  依赖: %GH_EXE% %GH_REPO% %TAG% %V_CODE% %APK_PATH%
REM  说明: Release 已存在时改为更新说明 + 覆盖上传，避免重复构建时报 "already exists"
REM ============================================
:gh_release
if "%APK_PATH%"=="" (
    echo [错误] APK 路径为空，无法上传 Release！
    exit /b 1
)
if not exist "%APK_PATH%" (
    echo [错误] APK 不存在: %APK_PATH%
    exit /b 1
)
"%GH_EXE%" release view "%TAG%" --repo "%GH_REPO%" >nul 2>&1
if errorlevel 1 (
    echo       创建 Release %TAG% 并上传 APK...
    "%GH_EXE%" release create "%TAG%" "%APK_PATH%" ^
        --title "%TAG%" ^
        --notes "ClipboardMerger %TAG% (build %V_CODE%)" ^
        --repo "%GH_REPO%"
) else (
    echo       Release %TAG% 已存在，更新说明并覆盖上传 APK...
    "%GH_EXE%" release edit "%TAG%" ^
        --title "%TAG%" ^
        --notes "ClipboardMerger %TAG% (build %V_CODE%)" ^
        --repo "%GH_REPO%" >nul 2>&1
    "%GH_EXE%" release upload "%TAG%" "%APK_PATH%" --clobber --repo "%GH_REPO%"
)
if errorlevel 1 (
    echo [错误] gh 返回失败，请检查: gh auth status / 网络 / 标签 %TAG% 是否已存在
    exit /b 1
)
echo       Release 链接:
"%GH_EXE%" release view "%TAG%" --repo "%GH_REPO%" --json url --template "{{.url}}"
echo.
exit /b 0

REM ============================================
REM  60秒倒计时关闭窗口
REM ============================================
:countdown
echo.
echo 所有步骤已完成，窗口将在 60 秒后自动关闭，按任意键立即关闭...
timeout /t 60
goto :eof