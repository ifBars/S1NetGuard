[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$reproRoot = Join-Path $PSScriptRoot "Repro"
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("S1NetGuard.Validator." + [Guid]::NewGuid().ToString("N"))

try {
    $tracked = @(& git -C $repoRoot ls-files)
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files failed with exit code $LASTEXITCODE."
    }

    $scripts = @($tracked | Where-Object {
        $_ -match '^tests/.+\.ps1$'
    } | ForEach-Object {
        Get-Item -LiteralPath (Join-Path $repoRoot $_)
    })
    foreach ($script in $scripts) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            $details = ($errors | ForEach-Object {
                "$($script.FullName):$($_.Extent.StartLineNumber): $($_.Message)"
            }) -join [Environment]::NewLine
            throw "PowerShell parse failure:$([Environment]::NewLine)$details"
        }
    }
    Write-Output "PASS|S1NetGuard.PowerShellParse|$($scripts.Count) scripts"

    & dotnet run --project (Join-Path $PSScriptRoot "S1NetGuard.PolicyVerifier\S1NetGuard.PolicyVerifier.csproj") -c Release
    if ($LASTEXITCODE -ne 0) {
        throw "Admission policy verifier failed with exit code $LASTEXITCODE."
    }

    & (Join-Path $reproRoot "Test-LiveValveVerifierFixtures.ps1") -OutputRoot $fixtureRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Live evidence verifier fixtures failed with exit code $LASTEXITCODE."
    }

    $forbidden = @($tracked | Where-Object {
        $_ -match '(?i)(^|/)(artifacts|\.codex-tmp)/' -or
        $_ -match '(?i)\.(dll|pdb|deps\.json|zip)$' -or
        $_ -eq 'reports/message-to-leo.md'
    })
    if ($forbidden.Count -gt 0) {
        throw "Tracked private or binary artifacts: $($forbidden -join ', ')"
    }

    Write-Output "PASS|S1NetGuard.RepositoryValidation"
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedFixture = [System.IO.Path]::GetFullPath($fixtureRoot)
        if (-not $resolvedFixture.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($resolvedFixture) -notlike 'S1NetGuard.Validator.*') {
            throw "Refusing to remove unexpected fixture path: $resolvedFixture"
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
