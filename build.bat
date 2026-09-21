@echo off
chcp 65001 > nul
title ClipboardMerger Build

REM ============================================
REM  ClipboardMerger 一键构建脚本
REM  用法: 双击运行        (构建+递增版本)
REM        build setup     (安装 Android SDK 组件)
REM        build clean     (清理构建产物)
REM        build release   (构建+Git推送+GitHub Release)
REM ============================================

set "JAVA_HOME=D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle"
set "ANDROID_HOME=D:\Tools\DevTools\Android\Sdk"
set "ANDROID_SDK_ROOT=D:\Tools\DevTools\Android\Sdk"
set "PATH=D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle\bin;D:\Tools\DevTools\gradle\gradle-8.5\bin;C:\Program Files\GitHub CLI;%PATH%"

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
pause
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
pause
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

echo [1/4] 递增版本号...
call "D:\Tools\DevTools\gradle\gradle-8.5\bin\gradle.bat" incrementVersion --no-daemon --console=plain
if %ERRORLEVEL% neq 0 (
    echo [错误] 版本号递增失败！Exit code=%ERRORLEVEL%
    pause
    exit /b 1
)
echo       完成。

echo [2/4] 清理旧产物...
call "D:\Tools\DevTools\gradle\gradle-8.5\bin\gradle.bat" clean --no-daemon --console=plain
echo       完成。

echo [3/4] 编译 APK（请耐心等待）...
call "D:\Tools\DevTools\gradle\gradle-8.5\bin\gradle.bat" assembleDebug --no-daemon --console=plain
set BUILD_EXIT=%ERRORLEVEL%

echo.
if %BUILD_EXIT% neq 0 (
    echo ============================================
    echo  构建失败！Exit code=%BUILD_EXIT%
    echo ============================================
    pause
    exit /b 1
)

echo ============================================
echo  构建成功！
echo ============================================
if exist "*.apk" del /q "*.apk" 2>nul
for /f "delims=" %%f in ('dir /s /b build\outputs\apk\debug\*.apk 2^>nul') do (
    copy /y "%%f" "." > nul
    echo  APK: %%~nxf  (%%~zf bytes)
)
echo.
echo  APK 已复制到项目根目录。
echo.
pause
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
where gh >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [错误] GitHub CLI (gh) 未安装或不在PATH中！
    echo        安装: winget install --id GitHub.cli
    pause
    exit /b 1
)
for /f "tokens=3" %%i in ('gh --version 2^>^&1 ^| findstr /r "^gh version"') do echo       gh版本: %%i

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
call git commit -m "release: %TAG% (build %V_CODE%)"
if %ERRORLEVEL% neq 0 (
    echo [警告] git commit 失败或无变更
)

echo       推送代码...
call git push origin main
if %ERRORLEVEL% neq 0 (
    echo [错误] git push 失败！
    pause
    exit /b 1
)

echo       创建标签 %TAG%...
call git tag -a "%TAG%" -m "Release %TAG% - build %V_CODE%"
call git push origin "%TAG%"
if %ERRORLEVEL% neq 0 (
    echo [错误] tag push 失败！
    pause
    exit /b 1
)

echo       创建GitHub Release并上传APK...
call gh release create "%TAG%" "%APK_PATH%" ^
    --title "%TAG%" ^
    --notes "ClipboardMerger %TAG% (build %V_CODE%)" ^
    --repo xiaobailong/ClipboardMerger
if %ERRORLEVEL% neq 0 (
    echo [错误] GitHub Release创建失败！
    pause
    exit /b 1
)

echo.
echo ============================================
echo  发布成功！
echo  版本: %TAG%
echo  APK:  %APK_PATH%
echo  GitHub Release已创建并上传APK
echo ============================================
echo.
pause
exit /b 0