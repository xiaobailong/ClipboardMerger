@echo off
chcp 65001 > nul
title 剪集 Clean

REM ============================================
REM  剪集 清理构建产物脚本
REM  用途: 清理 Android (Gradle) 和鸿蒙 (hvigor) 的构建输出、缓存和产物
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

echo.
echo ============================================
echo  剪集 清理构建产物
echo ============================================
echo.

echo [1/10] Gradle clean...
pushd android
call "D:\Tools\DevTools\gradle\gradle-8.5\bin\gradle.bat" clean --no-daemon --console=plain 2>nul
popd
if %ERRORLEVEL% neq 0 (
    echo [警告] gradle clean 未完全成功，继续手动清理...
)
echo       完成。

echo [2/10] 清理根 build 目录（旧版本残留）...
if exist "build" (
    rmdir /s /q "build" 2>nul
    echo       已删除 build 目录。
) else (
    echo       build 目录不存在，跳过。
)

echo [3/10] 清理 Gradle 缓存 (.gradle)...
if exist "android\.gradle" (
    rmdir /s /q "android\.gradle" 2>nul
    echo       已删除 android\.gradle 目录。
) else (
    echo       android\.gradle 目录不存在，跳过。
)

echo [4/10] 清理 Android build 目录...
if exist "android\build" (
    rmdir /s /q "android\build" 2>nul
    echo       已删除 android\build 目录。
) else (
    echo       android\build 目录不存在，跳过。
)
if exist "android\app\build" (
    rmdir /s /q "android\app\build" 2>nul
    echo       已删除 android\app\build 目录。
) else (
    echo       android\app\build 目录不存在，跳过。
)

echo [5/10] 清理输出产物...
if exist "android\*.apk" (
    del /q "android\*.apk" 2>nul
    echo       已删除 apk 文件。
) else (
    echo       无 apk 文件，跳过。
)
if exist "android\*.aab" (
    del /q "android\*.aab" 2>nul
    echo       已删除 aab 文件。
) else (
    echo       无 aab 文件，跳过。
)

echo [6/10] 清理 Cline 临时目录 tmp...
if exist "tmp" (
    rmdir /s /q "tmp" 2>nul
    echo       已删除 tmp 目录。
) else (
    echo       tmp 目录不存在，跳过。
)

echo.
echo ==== 鸿蒙构建产物 ====
echo.

echo [7/10] 清理 harmony\.hvigor 缓存...
if exist "harmony\.hvigor" (
    rmdir /s /q "harmony\.hvigor" 2>nul
    echo       已删除 harmony\.hvigor 目录。
) else (
    echo       harmony\.hvigor 目录不存在，跳过。
)

echo [8/10] 清理 harmony 构建输出...
if exist "harmony\build" (
    rmdir /s /q "harmony\build" 2>nul
    echo       已删除 harmony\build 目录。
) else (
    echo       harmony\build 目录不存在，跳过。
)
if exist "harmony\entry\build" (
    rmdir /s /q "harmony\entry\build" 2>nul
    echo       已删除 harmony\entry\build 目录。
) else (
    echo       harmony\entry\build 目录不存在，跳过。
)

echo [9/10] 清理 harmony\oh_modules...
if exist "harmony\oh_modules" (
    rmdir /s /q "harmony\oh_modules" 2>nul
    echo       已删除 harmony\oh_modules 目录。
) else (
    echo       harmony\oh_modules 目录不存在，跳过。
)

echo [10/10] 清理鸿蒙产物目录 build\harmony 和根目录 *.hap...
if exist "build\harmony" (
    rmdir /s /q "build\harmony" 2>nul
    echo       已删除 build\harmony 目录。
) else (
    echo       build\harmony 目录不存在，跳过。
)
if exist "*.hap" (
    del /q "*.hap" 2>nul
    echo       已删除 hap 文件。
) else (
    echo       无 hap 文件，跳过。
)

echo.
echo ============================================
echo  清理完成！
echo ============================================
echo.
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