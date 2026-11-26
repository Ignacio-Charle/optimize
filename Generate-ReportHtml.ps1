[CmdletBinding()]
param(
    [string]$InputJson = '',
    [string]$OutputHtml = '',
    [ValidateRange(1,10080)]
    [int]$StaleAfterMinutes = 150,
    [switch]$SyntheticExample
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) { $scriptRoot = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($InputJson)) { $InputJson = Join-Path $scriptRoot 'reports\latest-report.json' }
if ([string]::IsNullOrWhiteSpace($OutputHtml)) { $OutputHtml = Join-Path $scriptRoot 'reports\latest-report.html' }

function ConvertTo-HtmlText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    [Security.SecurityElement]::Escape([string]$Value)
}

if ($SyntheticExample) {
    $report = [pscustomobject]@{
        schemaVersion = 1
        timestampUtc = '2026-11-26T12:00:00Z'
        status = 'partial'
        stale = $false
        collectors = [pscustomobject]@{
            ram = [pscustomobject]@{ status='ok'; totalBytes=16492674417; availableBytes=4123168604; usedBytes=12369515813; usedPct=75.0 }
            cpu = [pscustomobject]@{ status='failed'; usedPct=$null; sampleSeconds=2 }
            disk = [pscustomobject]@{ status='ok'; systemVolume='C:'; totalBytes=476556337152; freeBytes=292238418739; freePct=61.3 }
        }
        cleanup = [pscustomobject]@{ enabled=$false; mode='Blocked'; eligible=0; omitted=0; deleted=0; failed=0 }
        alerts = [pscustomobject]@{ ram=$false; disk=$false }
        diagnosticIds = @('CPU: ejemplo sintético sin datos')
    }
} else {
    if (-not (Test-Path -LiteralPath $InputJson -PathType Leaf)) { throw "No existe el informe JSON: $InputJson" }
    $jsonText = [IO.File]::ReadAllText($InputJson, (New-Object Text.UTF8Encoding($false)))
    if ([string]::IsNullOrWhiteSpace($jsonText)) { throw 'El informe JSON está vacío.' }
    $report = $jsonText | ConvertFrom-Json
    if ($report.schemaVersion -ne 1) { throw "Versión de esquema incompatible: $($report.schemaVersion)" }
}

try {
    $sampleUtc = [datetimeoffset]::Parse([string]$report.timestampUtc)
    $isStale = $sampleUtc.ToUniversalTime() -lt ([datetimeoffset]::UtcNow.AddMinutes(-$StaleAfterMinutes))
    $report | Add-Member -NotePropertyName stale -NotePropertyValue ([bool]$isStale) -Force
} catch {
    $report | Add-Member -NotePropertyName stale -NotePropertyValue $true -Force
}

$ramStatus = [string]$report.collectors.ram.status
$cpuStatus = [string]$report.collectors.cpu.status
$diskStatus = [string]$report.collectors.disk.status
$ram = if ($null -ne $report.collectors.ram.usedPct) { '{0:N1}%' -f [double]$report.collectors.ram.usedPct } else { 'Dato ausente' }
$cpu = if ($null -ne $report.collectors.cpu.usedPct) { '{0:N1}% durante {1} s' -f [double]$report.collectors.cpu.usedPct,[int]$report.collectors.cpu.sampleSeconds } else { 'Dato ausente' }
$disk = if ($null -ne $report.collectors.disk.freePct) { '{0:N1}% libre de {1:N2} GiB' -f [double]$report.collectors.disk.freePct,([double]$report.collectors.disk.totalBytes / 1GB) } else { 'Dato ausente' }
$staleText = if ([bool]$report.stale) { 'ANTIGUO' } else { 'Actual' }
$statusText = [string]$report.status

$html = @"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
<title>Informe de memoria del PC</title>
<style>
:root { color-scheme: light dark; font-family: Segoe UI, Arial, sans-serif; }
body { max-width: 64rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; }
.status { border-left: 0.35rem solid #777; padding: 0.5rem 1rem; }
.ok { border-left-color: #16833b; }
.partial { border-left-color: #b26a00; }
.failed { border-left-color: #b00020; }
table { width: 100%; border-collapse: collapse; }
th, td { border: 1px solid #777; padding: 0.5rem; text-align: left; }
caption { text-align: left; font-weight: 700; margin-bottom: 0.25rem; }
:focus-visible { outline: 3px solid #0067b8; outline-offset: 2px; }
@media (max-width: 42rem) { table, tbody, tr, th, td { display: block; } th { margin-top: 0.5rem; } }
</style>
</head>
<body>
<main>
<h1 tabindex="-1">Informe de memoria del PC</h1>
<p class="status $(ConvertTo-HtmlText $statusText)">Estado: <strong>$(ConvertTo-HtmlText $statusText)</strong> · Datos: <strong>$staleText</strong></p>
<p>Hora UTC de la muestra: <time datetime="$(ConvertTo-HtmlText $report.timestampUtc)">$(ConvertTo-HtmlText $report.timestampUtc)</time></p>
<table>
<caption>Resumen de recursos</caption>
<thead><tr><th scope="col">Recurso</th><th scope="col">Estado</th><th scope="col">Valor</th></tr></thead>
<tbody>
<tr><th scope="row">RAM</th><td>$(ConvertTo-HtmlText $ramStatus)</td><td>$ram</td></tr>
<tr><th scope="row">CPU</th><td>$(ConvertTo-HtmlText $cpuStatus)</td><td>$cpu</td></tr>
<tr><th scope="row">Disco: $(ConvertTo-HtmlText $report.collectors.disk.systemVolume)</th><td>$(ConvertTo-HtmlText $diskStatus)</td><td>$disk</td></tr>
</tbody>
</table>
<h2>Limpieza</h2>
<p>Activada: $(if ([bool]$report.cleanup.enabled) {'sí'} else {'no'}) · Estado: $(ConvertTo-HtmlText $report.cleanup.mode).</p>
<p>Elegibles: $(ConvertTo-HtmlText $report.cleanup.eligible); eliminados: $(ConvertTo-HtmlText $report.cleanup.deleted); omitidos: $(ConvertTo-HtmlText $report.cleanup.omitted); fallidos: $(ConvertTo-HtmlText $report.cleanup.failed).</p>
<h2>Diagnóstico</h2>
<ul>
$(@($report.diagnosticIds | ForEach-Object { '<li>' + (ConvertTo-HtmlText $_) + '</li>' }) -join "`n")
</ul>
</main>
</body>
</html>
"@

$outputParent = Split-Path -Parent $OutputHtml
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}
$tempOutput = Join-Path $outputParent ('.' + [IO.Path]::GetRandomFileName())
try {
    [IO.File]::WriteAllText($tempOutput, $html, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $OutputHtml -PathType Leaf) {
        $backupOutput = $tempOutput + '.bak'
        [IO.File]::Replace($tempOutput, $OutputHtml, $backupOutput)
        if (Test-Path -LiteralPath $backupOutput -PathType Leaf) {
            Remove-Item -LiteralPath $backupOutput -Force -ErrorAction SilentlyContinue
        }
    } else {
        [IO.File]::Move($tempOutput, $OutputHtml)
    }
} catch [IO.IOException] {
    if (Test-Path -LiteralPath $OutputHtml -PathType Leaf) { throw "No se pudo reemplazar '$OutputHtml': $($_.Exception.Message)" }
    throw
} finally {
    if (Test-Path -LiteralPath $tempOutput -PathType Leaf) {
        Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
    }
}
Write-Output "Informe HTML generado: $OutputHtml"
