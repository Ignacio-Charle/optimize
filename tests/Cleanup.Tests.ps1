$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'MemoryMonitor.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FALLO: $Message" }
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
    Assert-True ($simulation.Eligible -eq 1) 'solo el archivo antiguo no protegido debería ser elegible'
    Assert-True (-not (Test-NoReparseAncestors -Path (Join-Path $junctionPath 'outside-old.tmp') -Root $testRoot)) 'un archivo alcanzado por junction debe fallar la comprobación de ancestros'
    Assert-True ((Test-Path -LiteralPath $recentFile) -and (Test-Path -LiteralPath $oldFile)) 'la simulación no debe borrar archivos'
    $real = Invoke-SafeTempCleanup -CleanupMode Clean -RootPath $testRoot -AuthorizedRoot $testRoot -AgeDays 7
    Assert-True ($real.Deleted -eq 1) 'debería eliminar exactamente el archivo antiguo elegible'
    Assert-True (-not (Test-Path -LiteralPath $oldFile)) 'el archivo antiguo debería haberse eliminado'
    Assert-True (Test-Path -LiteralPath $recentFile) 'el archivo reciente debe conservarse'
    Assert-True (Test-Path -LiteralPath $protectedFile) 'el archivo de caché debe conservarse'
    Assert-True (Test-Path -LiteralPath $outsideOldFile) 'no debe seguir ni borrar archivos de un junction'

    $rejected = $false
    try {
        Invoke-SafeTempCleanup -CleanupMode Clean -RootPath $outsideRoot -AuthorizedRoot $testRoot -AgeDays 7 | Out-Null
    } catch { $rejected = $true }
    Assert-True $rejected 'debe rechazarse una ruta fuera de la raíz autorizada'
    Write-Output 'PASS: simulación no destructiva, umbral de antigüedad, conservación de reciente/caché, omisión de junction y rechazo de ruta externa.'
} finally {
    if (Test-Path -LiteralPath $junctionPath) {
        try { [IO.Directory]::Delete($junctionPath) } catch { Write-Warning "No se pudo retirar el junction de prueba: $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outsideRoot -Recurse -Force -ErrorAction SilentlyContinue
}
