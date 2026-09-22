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
echo [%_CM_LOG_TS%] ClipboardMerger Build Start > "%_CM_LOGFILE%"
"%~f0" %* 2>&1 | powershell -NoProfile -Command "$input | ForEach-Object { $_ | Out-File -FilePath '%_CM_LOGFILE%' -Append -Encoding utf8; Write-Output $_ }"
echo ============================================ >> "%_CM_LOGFILE%"
echo 日志已保存: %_CM_LOGFILE%
timeout /t 10 > nul
exit /b %ERRORLEVEL%

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
for /f "delims=" %%f in ('dir /s /b build\outputs\apk\debug\*.apk 2^>nul') do (
    copy /y "%%f" "." > nul
    set "APK_PATH=%%f"
    echo  APK: %%~nxf  (%%~zf bytes)
)
echo.
echo  APK 已复制到项目根目录。
echo.

echo [4/5] 发布到 GitHub Release...
echo.
echo       检查gh CLI...
if not exist "%GH_EXE%" (
    echo [错误] GitHub CLI ^(gh^) 未安装！
    echo        路径: %GH_EXE%
    echo        安装: winget install --id GitHub.cli
    call :countdown
    exit /b 1
)
for /f "usebackq tokens=3" %%i in (`"%GH_EXE%" --version 2^>nul ^| findstr /r "^gh version"`) do echo       gh版本: %%i

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
    call git push origin main
    if errorlevel 1 (
        echo [错误] git push 失败！
        call :countdown
        exit /b 1
    )

    echo       创建标签 %TAG%...
    call git tag -a "%TAG%" -m "Release %TAG% - build %V_CODE%"
    call git push origin "%TAG%"
    if errorlevel 1 (
        echo [错误] tag push 失败！
        call :countdown
        exit /b 1
    )

    echo       创建GitHub Release并上传APK...
    call "%GH_EXE%" release create "%TAG%" "%APK_PATH%" ^
        --title "%TAG%" ^
        --notes "ClipboardMerger %TAG% (build %V_CODE%)" ^
        --repo xiaobailong/ClipboardMerger
    if errorlevel 1 (
        echo [错误] GitHub Release创建失败！
        call :countdown
        exit /b 1
    )
) else (
    echo       版本号未变更（已提交），检测推送状态...
    call git diff origin/main..HEAD --quiet
    if errorlevel 1 (
        echo       有未推送的提交，正在推送...
        call git push origin main
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
    call git push origin "%TAG%" -f
    if errorlevel 1 (
        echo [错误] tag push 失败！
        call :countdown
        exit /b 1
    )

    echo       创建GitHub Release并上传APK...
    call "%GH_EXE%" release create "%TAG%" "%APK_PATH%" ^
        --title "%TAG%" ^
        --notes "ClipboardMerger %TAG% (build %V_CODE%)" ^
        --repo xiaobailong/ClipboardMerger
    if errorlevel 1 (
        echo [警告] Release创建失败(可能已存在)，请手动检查
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
if not exist "%GH_EXE%" (
    echo [错误] GitHub CLI ^(gh^) 未安装！
    echo        路径: %GH_EXE%
    echo        安装: winget install --id GitHub.cli
    pause
    exit /b 1
)
for /f "usebackq tokens=3" %%i in (`"%GH_EXE%" --version 2^>nul ^| findstr /r "^gh version"`) do echo       gh版本: %%i

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
    call git push origin main
    if errorlevel 1 (
        echo [错误] git push 失败！
        pause
        exit /b 1
    )

    echo       创建标签 %TAG%...
    call git tag -a "%TAG%" -m "Release %TAG% - build %V_CODE%"
    call git push origin "%TAG%"
    if errorlevel 1 (
        echo [错误] tag push 失败！
        pause
        exit /b 1
    )

    echo       创建GitHub Release并上传APK...
    call "%GH_EXE%" release create "%TAG%" "%APK_PATH%" ^
        --title "%TAG%" ^
        --notes "ClipboardMerger %TAG% (build %V_CODE%)" ^
        --repo xiaobailong/ClipboardMerger
    if errorlevel 1 (
        echo [错误] GitHub Release创建失败！
        pause
        exit /b 1
    )
) else (
    echo       版本号未变更（已提交），检测推送状态...
    call git diff origin/main..HEAD --quiet
    if errorlevel 1 (
        echo       有未推送的提交，正在推送...
        call git push origin main
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
    call git push origin "%TAG%" -f
    if errorlevel 1 (
        echo [错误] tag push 失败！
        pause
        exit /b 1
    )

    echo       创建GitHub Release并上传APK...
    call "%GH_EXE%" release create "%TAG%" "%APK_PATH%" ^
        --title "%TAG%" ^
        --notes "ClipboardMerger %TAG% (build %V_CODE%)" ^
        --repo xiaobailong/ClipboardMerger
    if errorlevel 1 (
        echo [警告] Release创建失败(可能已存在)，请手动检查
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
REM  60秒倒计时关闭窗口
REM ============================================
:countdown
echo.
echo 所有步骤已完成，窗口将在 60 秒后自动关闭，按任意键立即关闭...
timeout /t 60
goto :eof