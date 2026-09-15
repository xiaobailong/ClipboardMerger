@echo off
chcp 65001 > nul
title ClipboardMerger Build

REM ============================================
REM  ClipboardMerger 一键构建脚本
REM  用法: 双击运行     (构建+递增版本)
REM        build setup  (安装 Android SDK 组件)
REM        build clean  (清理构建产物)
REM ============================================

set "JAVA_HOME=D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle"
set "ANDROID_HOME=D:\Tools\DevTools\Android\Sdk"
set "ANDROID_SDK_ROOT=D:\Tools\DevTools\Android\Sdk"
set "PATH=D:\Tools\DevTools\Java\JDK\jdk-21.0.10-oracle\bin;D:\Tools\DevTools\gradle\gradle-8.5\bin;%PATH%"

cd /d d:\WorkSpace\test\ClipboardMerger 2>nul || (
    echo [错误] 项目目录不存在
    pause
    exit /b 1
)

if not exist "build" mkdir "build"

if /i "%~1"=="setup"  goto :setup
if /i "%~1"=="clean"  goto :clean
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
for /f "delims=" %%f in ('dir /s /b build\outputs\apk\debug\*.apk 2^>nul') do (
    copy /y "%%f" "." > nul
    echo  APK: %%~nxf  (%%~zf bytes)
)
echo.
echo  APK 已复制到项目根目录。
echo.
pause
exit /b 0