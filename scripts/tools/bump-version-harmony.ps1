# =============================================================================
#  bump-version-harmony.ps1 - bump the patch of HarmonyOS versionName (called by build-harmony.bat)
#
#  WHY THIS FILE EXISTS
#  Same reason as bump_version.ps1 (and privi's bump_version.ps1):
#  locked-down endpoint policy silently blocks -Command regex invocations (rc=786);
#  the same logic through -File is unaffected.
#
#  VERSION SCHEME
#  harmony/AppScope/app.json5 holds "versionName" as the single source of truth.
#  Every build bumps the patch (+1), carry at 100:
#    x.y.99 -> x.(y+1).0
#    x.99.99 -> (x+1).0.0
#  "versionCode" is kept in sync as: 1000000 + major*10000 + minor*100 + patch
#  （基数 1000000 = 抬历史包袱：AGC 已发布过 versionCode 100013，早期本机装机版
#    还有 1000012，旧公式 major*10000+minor*100+patch 永远追不上 ⇒ 一律加百万基数，
#    既保证单调递增，也保证 patch/minor 进位规则不变）
#
#  USAGE
#    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\tools\bump-version-harmony.ps1
#
#  OUTPUT (stdout, single line)
#    OK=<old>-><new>|<versionCode>   file updated, exit code 0
#    ERROR=<reason>                  nothing written, exit code != 0
# =============================================================================
param()

$ErrorActionPreference = 'Stop'

$jsonFile = Join-Path $PSScriptRoot '..\..\harmony\AppScope\app.json5'

try {
    if (-not (Test-Path $jsonFile)) {
        Write-Output 'ERROR=app.json5-not-found'
        exit 2
    }

    $text = [IO.File]::ReadAllText($jsonFile)
    $m = [regex]::Match($text, '"versionName"\s*:\s*"(\d+)\.(\d+)\.(\d+)"')
    if (-not $m.Success) {
        Write-Output 'ERROR=versionName-not-three-part'
        exit 4
    }

    $major = [int]$m.Groups[1].Value
    $minor = [int]$m.Groups[2].Value
    $patch = [int]$m.Groups[3].Value
    $old = "$major.$minor.$patch"

    $patch += 1
    if ($patch -ge 100) {
        $patch = 0
        $minor += 1
    }
    if ($minor -ge 100) {
        $minor = 0
        $major += 1
    }

    $new = "$major.$minor.$patch"
    $vcode = 1000000 + $major * 10000 + $minor * 100 + $patch

    # Write app.json5
    $out = $text -replace '"versionName"\s*:\s*"[\d.]+"', ('"versionName": "' + $new + '"')
    $out = $out -replace '"versionCode"\s*:\s*\d+', ('"versionCode": ' + $vcode)
    [IO.File]::WriteAllText($jsonFile, $out)

    Write-Output ('OK=' + $old + '->' + $new + '|' + $vcode)
    exit 0
}
catch {
    Write-Output ('ERROR=' + $_.Exception.Message)
    exit 1
}