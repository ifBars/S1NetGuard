[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Mono", "Il2Cpp")]
    [string]$Runtime,

    [Parameter(Mandatory = $true)]
    [string]$GamePath,

    [ValidateRange(15, 180)]
    [int]$TimeoutSeconds = 75
)

$ErrorActionPreference = "Stop"

$resolvedGamePath = [System.IO.Path]::GetFullPath($GamePath)
$modsRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedGamePath "Mods"))
$configuration = if ($Runtime -eq "Mono") { "Mono" } else { "Il2cpp" }
$framework = if ($Runtime -eq "Mono") { "netstandard2.1" } else { "net6.0" }
$fileName = if ($Runtime -eq "Mono") { "S1NetGuard_Mono.dll" } else { "S1NetGuard_Il2Cpp.dll" }
$repoRoot = Split-Path -Parent $PSScriptRoot
$source = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "bin\$configuration\$framework\$fileName"))
$target = [System.IO.Path]::GetFullPath((Join-Path $modsRoot $fileName))
$executable = Join-Path $resolvedGamePath "Schedule I.exe"

if (-not $target.StartsWith($modsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Resolved deployment target escaped the Mods directory: $target"
}
foreach ($required in @($source, $executable, $modsRoot)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required smoke-test path does not exist: $required"
    }
}

if (Test-Path -LiteralPath $target) {
    throw "Refusing to overwrite an existing mod: $target"
}

$existingProcesses = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -and
    [System.IO.Path]::GetFullPath($_.ExecutablePath).StartsWith($resolvedGamePath, [System.StringComparison]::OrdinalIgnoreCase)
})
if ($existingProcesses.Count -gt 0) {
    throw "Refusing to launch while Schedule I is already running from $resolvedGamePath."
}

$process = $null
$deployed = $false
try {
    Copy-Item -LiteralPath $source -Destination $target
    $deployed = $true
    $process = Start-Process -FilePath $executable -WorkingDirectory $resolvedGamePath -PassThru -WindowStyle Hidden

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastObserved = "waiting for MelonLoader log"
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($process.HasExited) {
            throw "Game exited before the startup marker. ExitCode=$($process.ExitCode)"
        }

        $logs = @(
            (Join-Path $resolvedGamePath "MelonLoader\Latest.log"),
            (Join-Path $resolvedGamePath "UserData\MelonLoader\Latest.log")
        ) | Where-Object { Test-Path -LiteralPath $_ }

        foreach ($log in $logs) {
            $content = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
            $guardLines = @($content -split "`r?`n" | Where-Object { $_ -match "S1NetGuard|S1 Net Guard" })
            if ($guardLines.Count -gt 0) {
                $lastObserved = ($guardLines | Select-Object -Last 8) -join " | "
            }

            $patchesReady = $content -match "\[S1NetGuard\] Installed 4/4 targeted RPC guard\(s\)\."
            $initialized = $content -match "S1 Net Guard 0\.1\.0 initialized\."
            $guardError = $guardLines -match "Failed|Exception|ERROR"
            if ($patchesReady -and $initialized) {
                if ($guardError) {
                    throw "S1NetGuard emitted an error during startup: $lastObserved"
                }

                Write-Output "PASS|S1NetGuard.RuntimeStartup|$Runtime|pid=$($process.Id)"
                return
            }
        }
    }

    throw "Timed out waiting for S1NetGuard startup markers. Last observed: $lastObserved"
}
finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(10000) | Out-Null
    }

    if ($deployed -and (Test-Path -LiteralPath $target)) {
        Remove-Item -LiteralPath $target -Force
    }
}
