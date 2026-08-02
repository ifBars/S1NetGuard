[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GamePath,
    [string]$OutputPath = (Join-Path $PSScriptRoot "live-valve-bundle")
)

$ErrorActionPreference = "Stop"
$resolvedGamePath = [System.IO.Path]::GetFullPath($GamePath)
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))

& dotnet build (Join-Path $PSScriptRoot "S1NetGuard.ReproProbe.csproj") -c Release -p:GamePath=$resolvedGamePath
if ($LASTEXITCODE -ne 0) {
    throw "Live Valve probe build failed."
}

& dotnet build (Join-Path $repoRoot "S1NetGuard.csproj") -c Mono -p:AutomateLocalDeployment=false
if ($LASTEXITCODE -ne 0) {
    throw "S1NetGuard Mono build failed."
}

New-Item -ItemType Directory -Path $resolvedOutputPath -Force | Out-Null
$allowedOutputNames = @(
    "README.md",
    "New-CleanMonoClone.ps1",
    "Run-LiveValveProbe.ps1",
    "S1NetGuard.AdmissionRepro.dll",
    "S1NetGuard_Mono.dll",
    "SHA256SUMS.txt",
    "Test-LiveValveEvidence.ps1"
)
$unexpectedOutput = @(Get-ChildItem -LiteralPath $resolvedOutputPath -Force | Where-Object {
    $_.Name -notin $allowedOutputNames
})
if ($unexpectedOutput.Count -gt 0) {
    $names = ($unexpectedOutput.Name | Sort-Object) -join ", "
    throw "Bundle output contains unexpected files or directories. Move private evidence elsewhere first: $names"
}

$probe = Join-Path $PSScriptRoot "bin\Release\netstandard2.1\S1NetGuard.AdmissionRepro.dll"
foreach ($source in @(
    $probe,
    (Join-Path $repoRoot "bin\Mono\netstandard2.1\S1NetGuard_Mono.dll"),
    (Join-Path $PSScriptRoot "Run-LiveValveProbe.ps1"),
    (Join-Path $PSScriptRoot "Test-LiveValveEvidence.ps1"),
    (Join-Path $PSScriptRoot "New-CleanMonoClone.ps1"),
    (Join-Path $PSScriptRoot "LIVE-VALVE.md")
)) {
    $destinationName = if ([System.IO.Path]::GetFileName($source) -eq "LIVE-VALVE.md") {
        "README.md"
    }
    else {
        [System.IO.Path]::GetFileName($source)
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $resolvedOutputPath $destinationName) -Force
}

$files = Get-ChildItem -LiteralPath $resolvedOutputPath -File |
    Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
    Sort-Object Name
$manifest = foreach ($file in $files) {
    "{0}  {1}" -f (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash, $file.Name
}
[System.IO.File]::WriteAllLines((Join-Path $resolvedOutputPath "SHA256SUMS.txt"), $manifest)

Write-Output "PASS|S1NetGuard.LiveValveBundle|path=$resolvedOutputPath"
