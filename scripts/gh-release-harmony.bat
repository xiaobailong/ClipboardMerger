@echo off
chcp 65001 > nul

REM ============================================
REM  ClipboardMerger - HarmonyOS standalone GitHub Release (gh only)
REM  Publishes the UNSIGNED .hap of the current HEAD to
REM  tag harmony-v<versionName> in repo xiaobailong/ClipboardMerger.
REM  No build, no version bump, no source commit.
REM
REM  Usage:
REM    gh-release-harmony.bat                publish, tag = harmony-v<versionName>, at HEAD
REM    gh-release-harmony.bat check          dry run: read-only checks, nothing written
REM    gh-release-harmony.bat [tag]          explicit tag, still points at HEAD
REM    gh-release-harmony.bat [tag] [hap]    explicit tag + explicit HAP path
REM  Env: GH_EXE / GH_REPO / GH_PROXY (optional; auto-probe 127.0.0.1:7897)
REM
REM  Upload target: an UNSIGNED hap
REM    build\harmony\JianJi-HarmonyOS-v<ver>-<build>-unsigned.hap
REM    Source: hvigor's entry-default-unsigned.hap (build output).
REM    A signed hap CANNOT be un-signed: HarmonyOS appends the signature block
REM    after the zip payload, so there is no zip entry to delete.
REM    Signed HAP and .app stay local: never in git, never on a Release.
REM
REM  IMPORTANT: keep every comment line ASCII-only. With chcp 65001, CJK text
REM  in the leading part of a .bat gets mis-parsed by cmd (line drift; pieces of
REM  comments run as commands) - PIT-026. CJK inside echo strings is fine.
REM ============================================

REM relaunch once in a fresh cmd: with code page 65001 already active the file is
REM re-read as UTF-8 from byte 0, so the lines above are parsed correctly
if defined _CM_HRELAUNCH goto :hrelaunched
set "_CM_HRELAUNCH=1"
cmd /d /s /c ""%~f0" %*"
set "_CM_HRC=%ERRORLEVEL%"
exit /b %_CM_HRC%

:hrelaunched
cd /d "%~dp0.."
title 剪集 鸿蒙 GitHub Release

REM ============================================
REM  log init (tee wrapper): every line goes to build\logs first, then console
REM  same wrapper as build.bat / build-harmony-signed.bat, see ADR-010
REM ============================================
if not defined _CM_LOG_ACTIVE goto :init_log
goto :skip_log

:init_log
set "_CM_LOG_ACTIVE=1"
if not exist "build\logs" mkdir "build\logs"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "_CM_LOG_TS=%%i"
set "_CM_HLOG=build\logs\gh-release-harmony_%_CM_LOG_TS%.log"
set "_CM_TEE=%~dp0tools\tee-log.ps1"
set "_CM_SELF=%~f0"
set "_CM_ARGS=%*"
echo 鸿蒙包发布到 GitHub Release（日志实时双写），日志文件: %_CM_HLOG%
if not exist "%_CM_TEE%" goto :log_legacy
powershell -NoProfile -ExecutionPolicy Bypass -File "%_CM_TEE%" -Log "%_CM_HLOG%"
set _CM_REL_RESULT=%ERRORLEVEL%
goto :log_done

:log_legacy
echo [警告] 缺少 tools\tee-log.ps1，退回“先写文件、结束再回显”模式
powershell -NoProfile -Command "[System.IO.File]::WriteAllText('%_CM_HLOG%', '[%_CM_LOG_TS%] ClipboardMerger HarmonyOS Release Start', [System.Text.UTF8Encoding]::new($true))"
call "%~f0" %* 1>> "%_CM_HLOG%" 2>&1
set _CM_REL_RESULT=%ERRORLEVEL%
type "%_CM_HLOG%"

:log_done
echo ----------------------------------------
echo 日志已保存: %_CM_HLOG%
echo ----------------------------------------
if defined _CM_NO_PAUSE exit /b %_CM_REL_RESULT%
timeout /t 10 > nul
exit /b %_CM_REL_RESULT%

:skip_log
REM help must be handled before variable setup and the proxy probe
if /i "%~1"=="help" goto :usage
if /i "%~1"=="-h"   goto :usage
if /i "%~1"=="/?"   goto :usage

set "HARMONY_DIR=%~dp0..\harmony"
set "HAP_OUT=%~dp0..\build\harmony"
set "VER_TOOL=%~dp0tools\harmony-version.js"
for %%i in ("%HARMONY_DIR%") do set "HARMONY_DIR=%%~fi"
for %%i in ("%HAP_OUT%") do set "HAP_OUT=%%~fi"
if not defined GH_EXE  set "GH_EXE=C:\Program Files\GitHub CLI\gh.exe"
if not defined GH_REPO set "GH_REPO=xiaobailong/ClipboardMerger"

REM gh is a Go binary: it honours http_proxy / https_proxy.
REM GH_PROXY wins; otherwise probe the local proxy port once (no-op when idle).
if not defined GH_PROXY for /f "usebackq delims=" %%a in (`curl -s -o nul --max-time 3 -w "%%{http_code}" -x http://127.0.0.1:7897 https://api.github.com`) do if "%%a"=="200" set "GH_PROXY=http://127.0.0.1:7897"
if not defined GH_PROXY goto :no_proxy
set "http_proxy=%GH_PROXY%"
set "https_proxy=%GH_PROXY%"
echo  [代理] 使用 GH_PROXY=%GH_PROXY%
:no_proxy

set "GH_TAG=%~1"
set "GH_HAP=%~2"
set "GH_DRY=0"
if /i "%GH_TAG%"=="check" (
    set "GH_DRY=1"
    set "GH_TAG=%~2"
    set "GH_HAP=%~3"
)

echo ============================================
echo  剪集 鸿蒙 GitHub Release - %date% %time%
echo ============================================
if "%GH_DRY%"=="1" echo  [预检 check] 只做只读检查，不会打标签 / 推送 / 发 Release
echo.

echo [1/6] 检查 gh CLI...
call :check_gh
if errorlevel 1 goto :fail

echo [2/6] 读取鸿蒙版本...
if not exist "%VER_TOOL%" (
    echo [错误] 找不到版本工具: %VER_TOOL%
    goto :fail
)
for /f %%i in ('node "%VER_TOOL%" name') do set "V_NAME=%%i"
for /f %%i in ('node "%VER_TOOL%" code') do set "V_CODE=%%i"
if not defined V_NAME (
    echo [错误] 读不到 versionName（harmony\AppScope\app.json5）
    goto :fail
)
if "%GH_TAG%"=="" set "GH_TAG=harmony-v%V_NAME%"
echo       版本: %GH_TAG% （build %V_CODE%）

echo [3/6] 定位并准备未签名 HAP...
call :prepare_hap
if errorlevel 1 goto :fail
for %%f in ("%HAP_PUB%") do echo       HAP: %%~nxf - %%~zf bytes

echo [4/6] 读取最后一个提交...
for /f "delims=" %%i in ('git log -1 --oneline') do set "GH_COMMIT=%%i"
if "%GH_COMMIT%"=="" (
    echo [错误] 读不到最后一个提交，当前目录不是 git 仓库？
    goto :fail
)
REM sanitize: strip chars cmd would re-parse (PIT-005 / ISSUE-004)
set "GH_COMMIT=%GH_COMMIT:"=%"
set "GH_COMMIT=%GH_COMMIT:&=/%"
set "GH_COMMIT=%GH_COMMIT:|=/%"
set "GH_COMMIT=%GH_COMMIT:(=%"
set "GH_COMMIT=%GH_COMMIT:)=%"
set "GH_COMMIT=%GH_COMMIT:<=/%"
set "GH_COMMIT=%GH_COMMIT:>=/%"
for /f "delims=" %%i in ('git rev-parse HEAD') do set "HEAD_SHA=%%i"
for /f "delims=" %%i in ('git rev-parse --abbrev-ref HEAD') do set "HEAD_BRANCH=%%i"
set "GH_NOTES=剪集 鸿蒙版 %GH_TAG%（build %V_CODE%，未签名 HAP） | %GH_COMMIT%"
echo       提交: %GH_COMMIT%
echo       分支: %HEAD_BRANCH%

echo [5/6] 检查标签与推送状态...
set "TAG_SHA="
git rev-parse -q --verify "refs/tags/%GH_TAG%" >nul 2>&1
if not errorlevel 1 for /f "delims=" %%i in ('git rev-list -n 1 "%GH_TAG%"') do set "TAG_SHA=%%i"
if "%TAG_SHA%"=="" goto :tag_new
if /i "%TAG_SHA%"=="%HEAD_SHA%" goto :tag_same
echo       [警告] 标签 %GH_TAG% 已存在，指向 %TAG_SHA%
echo              最后一个提交是 %HEAD_SHA%，继续会把远端标签移动到后者
if "%GH_DRY%"=="1" goto :push_state
set "CONFIRM="
set /p "CONFIRM=      确认移动标签并继续？(y/N) "
if /i not "%CONFIRM%"=="y" (
    echo [取消] 未做任何修改
    call :countdown
    exit /b 1
)
goto :push_state

:tag_new
echo       标签 %GH_TAG% 不存在，将新建并指向最后一个提交
goto :push_state

:tag_same
echo       标签 %GH_TAG% 已存在且指向最后一个提交

:push_state
set "NEED_PUSH=0"
call git diff "origin/%HEAD_BRANCH%..HEAD" --quiet >nul 2>&1
if errorlevel 1 set "NEED_PUSH=1"
if "%NEED_PUSH%"=="1" echo       有未推送的提交，将先 push %HEAD_BRANCH%
if "%NEED_PUSH%"=="0" echo       %HEAD_BRANCH% 已推送
git status --porcelain | findstr /r /c:"." >nul 2>&1
if not errorlevel 1 echo       [提示] 工作区有未提交改动，本脚本不会提交

REM remote tag already at HEAD means: skip tag + push (tag push uses SSH, see ADR-011)
set "REMOTE_TAG_SHA="
set "_RT_N=0"

:tag_check_try
set /a _RT_N+=1
REM gh api returns a 422 JSON body on stdout when the tag does not exist; that body
REM contains quotes and would break the next `if` (… was unexpected at this time),
REM so keep only a bare 40-char hex sha.
for /f "usebackq delims=" %%a in (`call "%GH_EXE%" api "repos/%GH_REPO%/commits/%GH_TAG%" --jq .sha 2^>nul ^| findstr /r /c:"^[0-9a-f][0-9a-f]*$"`) do set "REMOTE_TAG_SHA=%%a"
if not "%REMOTE_TAG_SHA%"=="" goto :tag_check_done
if %_RT_N% lss 3 (
    ping -n 3 127.0.0.1 > nul
    goto :tag_check_try
)

:tag_check_done
set "TAG_STATE=远端标签不等于 HEAD，将重新打标签并推送"
if /i "%REMOTE_TAG_SHA%"=="%HEAD_SHA%" set "TAG_STATE=远端标签已指向 HEAD，跳过打标签 / 推标签"
echo       远端标签: %TAG_STATE%
REM guard: keep the next logical line away from a CJK echo (PIT-026)

if "%GH_DRY%"=="1" goto :plan

echo [6/6] 发布 GitHub Release...
if "%NEED_PUSH%"=="1" (
    call :git_push "%HEAD_BRANCH%"
    if errorlevel 1 goto :fail
)

if /i "%REMOTE_TAG_SHA%"=="%HEAD_SHA%" goto :tag_already

echo       打标签 %GH_TAG% 指向最后一个提交...
call git tag -f -a "%GH_TAG%" -m "Release %GH_TAG%"
if errorlevel 1 (
    echo [错误] git tag 失败
    goto :fail
)
call :git_push "%GH_TAG%"
if errorlevel 1 (
    echo       [警告] 普通推送标签失败，改用强制推送...
    call :git_push "%GH_TAG%" force
    if errorlevel 1 goto :fail
)

:tag_already
echo       创建/更新 GitHub Release 并上传未签名 HAP...
call :gh_release
if errorlevel 1 goto :fail

echo.
echo ============================================
echo  发布成功！
echo  版本:  %GH_TAG%
echo  提交:  %GH_COMMIT%
echo  HAP:   %HAP_PUB%（未签名）
echo ============================================
call :countdown
exit /b 0

REM ============================================
REM  dry run: print the commands, execute nothing
REM ============================================
:plan
echo [6/6] 预检结果——以下命令都还没有执行:
if "%NEED_PUSH%"=="1" echo         git push origin %HEAD_BRANCH%
if /i not "%REMOTE_TAG_SHA%"=="%HEAD_SHA%" echo         git tag -f -a "%GH_TAG%" -m "Release %GH_TAG%"
if /i not "%REMOTE_TAG_SHA%"=="%HEAD_SHA%" echo         git push origin %GH_TAG%
"%GH_EXE%" release view "%GH_TAG%" --repo "%GH_REPO%" >nul 2>&1
if errorlevel 1 echo         "%GH_EXE%" release create "%GH_TAG%" "%HAP_PUB%" --title "%GH_TAG%" --notes "%GH_NOTES%" --repo "%GH_REPO%"
if not errorlevel 1 echo         "%GH_EXE%" release edit "%GH_TAG%" --title "%GH_TAG%" --notes "%GH_NOTES%" --repo "%GH_REPO%"
if not errorlevel 1 echo         "%GH_EXE%" release upload "%GH_TAG%" "%HAP_PUB%" --clobber --repo "%GH_REPO%"
echo.
echo [预检完成] 去掉 check 参数即可真正发布
call :countdown
exit /b 0

REM ============================================
REM  failure exit
REM ============================================
:fail
echo.
echo ============================================
echo  发布未完成，请按上面的错误信息处理后重试
echo ============================================
call :countdown
exit /b 1

:usage
echo.
echo 用法:
echo   gh-release-harmony.bat               发布（tag = harmony-v 版本号，指向 HEAD）
echo   gh-release-harmony.bat check         预检（只读，不写任何东西）
echo   gh-release-harmony.bat [tag]         显式 tag，仍指向 HEAD
echo   gh-release-harmony.bat [tag] [hap]   显式 tag + 显式 HAP 路径
echo.
echo 上传物: 只有未签名 HAP（签名 HAP / .app 仅本地，永不入 git、不上 Release）
echo 产物来源: hvigor 的 entry-default-unsigned.hap（签名包无法去签名，不会上传）
echo 版本号真源: harmony\AppScope\app.json5（scripts\tools\harmony-version.js）
echo 环境变量: GH_EXE / GH_REPO / GH_PROXY；自动化场景可设 _CM_NO_PAUSE=1 跳过倒计时
echo 出包: 先跑 scripts\build-harmony-signed.bat（本脚本不构建、不改版本号）
echo.
if defined _CM_NO_PAUSE exit /b 0
pause
exit /b 0

REM ============================================
REM  check gh CLI (exit /b 1 on failure)
REM ============================================
:check_gh
if not exist "%GH_EXE%" (
    echo [错误] GitHub CLI 未安装！
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
REM  locate + prepare an UNSIGNED hap
REM    outputs: HAP_SRC (source file), HAP_PUB (unsigned hap to upload)
REM ============================================
:prepare_hap
set "HAP_SRC=%GH_HAP%"
if defined HAP_SRC goto :hap_src_check
REM 1) hvigor unsigned artifact (entry-default-unsigned.hap) is the real unsigned hap
REM 2) an unsigned hap archived in build\harmony (copied from 1 by build-harmony-signed)
REM 3) any hap -> cannot be used, report a clear error (see below)
for /f "delims=" %%f in ('dir /b /s /o-d "%HARMONY_DIR%\entry\build\*unsigned*.hap" 2^>nul') do if not defined HAP_SRC set "HAP_SRC=%%f"
if defined HAP_SRC goto :hap_src_check
for /f "delims=" %%f in ('dir /b /o-d "%HAP_OUT%\*unsigned*.hap" 2^>nul') do if not defined HAP_SRC set "HAP_SRC=%HAP_OUT%\%%f"
if defined HAP_SRC goto :hap_src_check
for /f "delims=" %%f in ('dir /b /o-d "%HAP_OUT%\*.hap" 2^>nul') do if not defined HAP_SRC set "HAP_SIGNED_ONLY=%HAP_OUT%\%%f"
if defined HAP_SIGNED_ONLY goto :hap_no_unsigned
for /f "delims=" %%f in ('dir /b /s /o-d "%HARMONY_DIR%\entry\build\*.hap" 2^>nul') do if not defined HAP_SIGNED_ONLY set "HAP_SIGNED_ONLY=%%f"
if defined HAP_SIGNED_ONLY goto :hap_no_unsigned

echo [错误] 没找到任何 HAP：%HAP_OUT% 与 %HARMONY_DIR%\entry\build 都没有
echo        请先跑 scripts\build-harmony-signed.bat，或显式传路径: gh-release-harmony.bat tag hap路径
exit /b 1

:hap_no_unsigned
echo [错误] 只找到签名 HAP，拿不到未签名包: %HAP_SIGNED_ONLY%
echo        签名数据附加在 hap 文件尾部（不是 zip 条目），删不掉、无法无损去签名。
echo        请重跑 scripts\build-harmony-signed.bat —— 它会同时产出
echo        harmony\entry\build\default\outputs\default\entry-default-unsigned.hap
exit /b 1

:hap_src_check
if not exist "%HAP_SRC%" (
    echo [错误] HAP 不存在: %HAP_SRC%
    exit /b 1
)
echo %HAP_SRC% | findstr /i "unsigned" >nul
if errorlevel 1 (
    echo [错误] 传入的 HAP 不是未签名包: %HAP_SRC%
    echo        本脚本只发布未签名 HAP（签名包仅本地 / 上架 AGC 用）
    exit /b 1
)
if not exist "%HAP_OUT%" mkdir "%HAP_OUT%"
set "HAP_PUB=%HAP_OUT%\JianJi-HarmonyOS-v%V_NAME%-%V_CODE%-unsigned.hap"
echo       源文件: %HAP_SRC%
if /i "%HAP_SRC%"=="%HAP_PUB%" goto :hap_ready
copy /y "%HAP_SRC%" "%HAP_PUB%" >nul
if errorlevel 1 (
    echo [错误] 复制 HAP 失败: %HAP_PUB%
    exit /b 1
)

:hap_ready
echo       待上传: %HAP_PUB%（未签名；装机请用 build\harmony 里的签名包）
exit /b 0

REM ============================================
REM  git push with 3 retries: call :git_push REF [force]
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
REM  create / update Release + upload HAP (idempotent)
REM  needs: GH_EXE / GH_REPO / GH_TAG / GH_NOTES / HAP_PUB
REM ============================================
:gh_release
if "%GH_NOTES%"=="" set "GH_NOTES=ClipboardMerger HarmonyOS %GH_TAG%"
if not exist "%HAP_PUB%" (
    echo [错误] HAP 不存在: %HAP_PUB%
    exit /b 1
)

"%GH_EXE%" release view "%GH_TAG%" --repo "%GH_REPO%" >nul 2>&1
if not errorlevel 1 goto :gh_release_update

echo       创建 Release %GH_TAG% 并上传 HAP...
"%GH_EXE%" release create "%GH_TAG%" "%HAP_PUB%" --title "%GH_TAG%" --notes "%GH_NOTES%" --repo "%GH_REPO%"
if errorlevel 1 goto :gh_release_fail
goto :gh_release_done

:gh_release_update
echo       Release %GH_TAG% 已存在，更新说明并覆盖上传 HAP...
REM a draft release stays invisible until published; publish it here
set "REL_DRAFT="
for /f "usebackq delims=" %%a in (`call "%GH_EXE%" release view "%GH_TAG%" --repo "%GH_REPO%" --json isDraft --jq .isDraft 2^>nul`) do set "REL_DRAFT=%%a"
if /i "%REL_DRAFT%"=="true" echo       [提示] 该 Release 是草稿，将一并发布
REM guard: keep the next logical lines away from a CJK echo (PIT-026)
if /i "%REL_DRAFT%"=="true" "%GH_EXE%" release edit "%GH_TAG%" --title "%GH_TAG%" --notes "%GH_NOTES%" --repo "%GH_REPO%" --draft=false >nul 2>&1
if /i not "%REL_DRAFT%"=="true" "%GH_EXE%" release edit "%GH_TAG%" --title "%GH_TAG%" --notes "%GH_NOTES%" --repo "%GH_REPO%" >nul 2>&1
REM gh's GraphQL asset list can be stale: --clobber misses the old asset and the
REM upload fails with 422 "ReleaseAsset.name already exists" (PIT-027).
REM So drop the same-named asset through the REST API by id first.
for %%f in ("%HAP_PUB%") do set "HAP_NAME_ONLY=%%~nxf"
set "REL_ID="
for /f "usebackq delims=" %%a in (`call "%GH_EXE%" api "repos/%GH_REPO%/releases/tags/%GH_TAG%" --jq .id 2^>nul`) do set "REL_ID=%%a"
if "%REL_ID%"=="" goto :gh_release_upload
for /f "usebackq delims=" %%i in (`call "%GH_EXE%" api "repos/%GH_REPO%/releases/%REL_ID%/assets?per_page=100" --jq ".[].id" 2^>nul`) do call :drop_same_asset %%i "%HAP_NAME_ONLY%"

:gh_release_upload
"%GH_EXE%" release upload "%GH_TAG%" "%HAP_PUB%" --clobber --repo "%GH_REPO%"
if errorlevel 1 goto :gh_release_fail

:gh_release_done
echo       Release 链接:
"%GH_EXE%" release view "%GH_TAG%" --repo "%GH_REPO%" --json url --template "{{.url}}"
echo.
echo       Release 附件（只应有未签名 .hap）:
"%GH_EXE%" release view "%GH_TAG%" --repo "%GH_REPO%" --json assets --jq ".assets[].name"
exit /b 0

:gh_release_fail
echo [错误] gh 返回失败，请检查: gh auth status / 网络 / 标签 %GH_TAG% 是否已存在
exit /b 1

REM --- drop one release asset when its name matches (REST, id based) ---
:drop_same_asset
set "_DA_ID=%~1"
set "_DA_NAME="
for /f "usebackq delims=" %%n in (`call "%GH_EXE%" api "repos/%GH_REPO%/releases/assets/%_DA_ID%" --jq .name 2^>nul`) do set "_DA_NAME=%%n"
if /i not "%_DA_NAME%"=="%~2" exit /b 0
echo       清理同名旧资产: %_DA_NAME%
"%GH_EXE%" api -X DELETE "repos/%GH_REPO%/releases/assets/%_DA_ID%" >nul 2>&1
exit /b 0

REM ============================================
REM  countdown before closing the window (automation: set _CM_NO_PAUSE=1)
REM ============================================
:countdown
if defined _CM_NO_PAUSE goto :eof
echo.
echo 窗口将在 10 秒后自动关闭，按任意键立即关闭...
timeout /t 10
goto :eof
