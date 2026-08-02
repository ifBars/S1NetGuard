[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath
)

$ErrorActionPreference = "Stop"
$sourceRoot = [System.IO.Path]::GetFullPath($SourcePath)
$destinationRoot = [System.IO.Path]::GetFullPath($DestinationPath)
$sourcePrefix = $sourceRoot.TrimEnd('\') + '\'
$destinationPrefix = $destinationRoot.TrimEnd('\') + '\'

if (Test-Path -LiteralPath $destinationRoot) {
    throw "Destination already exists: $destinationRoot"
}
if ($destinationRoot.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
    $sourceRoot.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Source and destination must not contain one another."
}
if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot "Schedule I.exe") -PathType Leaf)) {
    throw "Schedule I source install not found: $sourceRoot"
}
$sourceSteamApi = Join-Path $sourceRoot "Schedule I_Data\Plugins\x86_64\steam_api64.dll"
if (-not (Test-Path -LiteralPath $sourceSteamApi -PathType Leaf)) {
    throw "Source Steam API not found: $sourceSteamApi"
}
$sourceSteamVersion = (Get-Item -LiteralPath $sourceSteamApi).VersionInfo
if ($sourceSteamVersion.CompanyName -ne "Valve Corporation") {
    throw "Source Steam API is not the Valve client API. Company=$($sourceSteamVersion.CompanyName)"
}

function New-FileLinkOrCopy {
    param([string]$Source, [string]$Destination)

    try {
        New-Item -ItemType HardLink -Path $Destination -Target $Source | Out-Null
    }
    catch {
        Copy-Item -LiteralPath $Source -Destination $Destination
    }
}

New-Item -ItemType Directory -Path $destinationRoot | Out-Null

foreach ($fileName in @(
    "Schedule I.exe",
    "UnityCrashHandler64.exe",
    "UnityPlayer.dll",
    "steam_appid.txt",
    "version.dll",
    "baselib.dll"
)) {
    $sourceFile = Join-Path $sourceRoot $fileName
    if (Test-Path -LiteralPath $sourceFile -PathType Leaf) {
        New-FileLinkOrCopy $sourceFile (Join-Path $destinationRoot $fileName)
    }
}

$monoRuntime = Join-Path $sourceRoot "MonoBleedingEdge"
if (Test-Path -LiteralPath $monoRuntime -PathType Container) {
    New-Item -ItemType Junction -Path (Join-Path $destinationRoot "MonoBleedingEdge") -Target $monoRuntime | Out-Null
}

$sourceData = Join-Path $sourceRoot "Schedule I_Data"
$destinationData = Join-Path $destinationRoot "Schedule I_Data"
New-Item -ItemType Directory -Path $destinationData | Out-Null
foreach ($item in Get-ChildItem -LiteralPath $sourceData -Force) {
    $destinationItem = Join-Path $destinationData $item.Name
    if ($item.PSIsContainer) {
        if ($item.Name -eq "Plugins") {
            Copy-Item -LiteralPath $item.FullName -Destination $destinationItem -Recurse
        }
        else {
            New-Item -ItemType Junction -Path $destinationItem -Target $item.FullName | Out-Null
        }
    }
    else {
        New-FileLinkOrCopy $item.FullName $destinationItem
    }
}

Copy-Item -LiteralPath (Join-Path $sourceRoot "MelonLoader") -Destination (Join-Path $destinationRoot "MelonLoader") -Recurse
foreach ($directory in @("Mods", "UserData", "UserLibs")) {
    New-Item -ItemType Directory -Path (Join-Path $destinationRoot $directory) | Out-Null
}

[System.IO.File]::WriteAllText(
    (Join-Path $destinationRoot ".s1ng-live-control-clone"),
    "CreatedUtc=$([DateTime]::UtcNow.ToString('O'))$([Environment]::NewLine)Source=$sourceRoot$([Environment]::NewLine)")

$steamApi = Join-Path $destinationData "Plugins\x86_64\steam_api64.dll"
Write-Output "PASS|S1NetGuard.CleanMonoClone|path=$destinationRoot|steamApiSha256=$((Get-FileHash -LiteralPath $steamApi -Algorithm SHA256).Hash)"
