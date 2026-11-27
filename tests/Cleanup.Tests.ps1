$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'MemoryMonitor.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("MemoryMonitor-test-" + [guid]::NewGuid().ToString('N'))
$outsideRoot = Join-Path ([IO.Path]::GetTempPath()) ("MemoryMonitor-outside-" + [guid]::NewGuid().ToString('N'))
$junctionPath = Join-Path $testRoot 'junction-outside'
New-Item -ItemType Directory -Path $testRoot | Out-Null
New-Item -ItemType Directory -Path $outsideRoot | Out-Null
try {
    $oldFile = Join-Path $testRoot 'old.tmp'
    $recentFile = Join-Path $testRoot 'recent.tmp'
    $protectedDir = Join-Path $testRoot 'Cache'
    New-Item -ItemType File -Path $oldFile | Out-Null
    New-Item -ItemType File -Path $recentFile | Out-Null
    New-Item -ItemType Directory -Path $protectedDir | Out-Null
    $protectedFile = Join-Path $protectedDir 'old-cache.tmp'
    $outsideOldFile = Join-Path $outsideRoot 'outside-old.tmp'
    New-Item -ItemType File -Path $protectedFile | Out-Null
    New-Item -ItemType File -Path $outsideOldFile | Out-Null
    New-Item -ItemType Junction -Path $junctionPath -Target $outsideRoot | Out-Null
    (Get-Item -LiteralPath $oldFile).LastWriteTime = (Get-Date).AddDays(-9)
    (Get-Item -LiteralPath $recentFile).LastWriteTime = (Get-Date).AddDays(-1)
    (Get-Item -LiteralPath $protectedFile).LastWriteTime = (Get-Date).AddDays(-9)
    (Get-Item -LiteralPath $outsideOldFile).LastWriteTime = (Get-Date).AddDays(-9)

    $simulation = Invoke-SafeTempCleanup -CleanupMode Simulate -RootPath $testRoot -AuthorizedRoot $testRoot -AgeDays 7
    Assert-True ($simulation.Eligible -eq 1) 'only the old unprotected file should be eligible'
    Assert-True (-not (Test-NoReparseAncestors -Path (Join-Path $junctionPath 'outside-old.tmp') -Root $testRoot)) 'a file reached through a junction must fail the ancestor check'
    Assert-True ((Test-Path -LiteralPath $recentFile) -and (Test-Path -LiteralPath $oldFile)) 'simulation must not delete files'
    $real = Invoke-SafeTempCleanup -CleanupMode Clean -RootPath $testRoot -AuthorizedRoot $testRoot -AgeDays 7
    Assert-True ($real.Deleted -eq 1) 'exactly the eligible old file should be deleted'
    Assert-True (-not (Test-Path -LiteralPath $oldFile)) 'the old file should have been deleted'
    Assert-True (Test-Path -LiteralPath $recentFile) 'the recent file must be preserved'
    Assert-True (Test-Path -LiteralPath $protectedFile) 'the cache file must be preserved'
    Assert-True (Test-Path -LiteralPath $outsideOldFile) 'files behind a junction must not be followed or deleted'

    $rejected = $false
    try {
        Invoke-SafeTempCleanup -CleanupMode Clean -RootPath $outsideRoot -AuthorizedRoot $testRoot -AgeDays 7 | Out-Null
    } catch { $rejected = $true }
    Assert-True $rejected 'a path outside the authorized root must be rejected'
    Write-Output 'PASS: non-destructive simulation, age threshold, recent/cache preservation, junction exclusion, and outside-path rejection.'
} finally {
    if (Test-Path -LiteralPath $junctionPath) {
        try { [IO.Directory]::Delete($junctionPath) } catch { Write-Warning "Could not remove test junction: $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outsideRoot -Recurse -Force -ErrorAction SilentlyContinue
}
