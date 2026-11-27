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
$localTimeText = try {
    ([datetimeoffset]::Parse([string]$report.timestampUtc).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss'))
} catch { 'No disponible' }
$ramTotalGiB = if ($null -ne $report.collectors.ram.totalBytes) { [math]::Round([double]$report.collectors.ram.totalBytes / 1GB, 2) } else { $null }
$ramAvailableGiB = if ($null -ne $report.collectors.ram.availableBytes) { [math]::Round([double]$report.collectors.ram.availableBytes / 1GB, 2) } else { $null }
$diskTotalGiB = if ($null -ne $report.collectors.disk.totalBytes) { [math]::Round([double]$report.collectors.disk.totalBytes / 1GB, 2) } else { $null }
$diskFreeGiB = if ($null -ne $report.collectors.disk.freeBytes) { [math]::Round([double]$report.collectors.disk.freeBytes / 1GB, 2) } else { $null }

$html = @"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
<title>Monitor de recursos de Windows</title>
<style>
:root {
  color-scheme: light dark;
  --canvas: #0b1220;
  --surface: #111b2d;
  --text: #edf3ff;
  --muted: #aab7ca;
  --line: #314158;
  --ok: #62d6a4;
  --warn: #ffc66d;
  --bad: #ff8e99;
  --focus: #85b8ff;
  font-family: "Segoe UI Variable Text", "Segoe UI", Arial, sans-serif;
}
@media (prefers-color-scheme: light) {
  :root {
    --canvas: #f4f7fb;
    --surface: #ffffff;
    --text: #172033;
    --muted: #536176;
    --line: #ccd5e3;
    --ok: #087a45;
    --warn: #8a5700;
    --bad: #a12636;
    --focus: #005fcc;
  }
}
* { box-sizing: border-box; }
body { max-width: 68rem; margin: 0 auto; padding: clamp(1.25rem, 4vw, 3rem); background: var(--canvas); color: var(--text); line-height: 1.55; }
main { min-width: 0; }
h1 { margin: 0 0 0.4rem; font-size: clamp(1.75rem, 5vw, 3rem); line-height: 1.08; letter-spacing: -0.035em; }
h2 { margin: 2rem 0 0.65rem; font-size: 1.15rem; }
.meta { color: var(--muted); margin: 0 0 1.5rem; }
.status { margin: 0 0 1.5rem; padding: 0.75rem 0; font-weight: 650; }
.status .label { display: inline-block; min-width: 6.5rem; }
.status.ok .label { color: var(--ok); }
.status.partial .label { color: var(--warn); }
.status.failed .label { color: var(--bad); }
.resource-table { width: 100%; border-collapse: collapse; background: var(--surface); }
.resource-table th, .resource-table td { border-bottom: 1px solid var(--line); padding: 0.85rem 1rem; text-align: left; overflow-wrap: anywhere; }
.resource-table thead th { color: var(--muted); font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.08em; }
.resource-table tbody th { width: 22%; }
.resource-table tr:last-child th, .resource-table tr:last-child td { border-bottom: 0; }
.value { font-variant-numeric: tabular-nums; font-weight: 700; }
.cleanup, .diagnostics { background: var(--surface); padding: 1rem; }
.cleanup p, .diagnostics p, .diagnostics li { overflow-wrap: anywhere; }
:focus-visible { outline: 3px solid var(--focus); outline-offset: 3px; }
@media (max-width: 42rem) {
  body { padding: 1rem; }
  .resource-table, .resource-table tbody, .resource-table tr { display: block; }
  .resource-table thead { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
  .resource-table tr { border-bottom: 1px solid var(--line); }
  .resource-table tr:last-child { border-bottom: 0; }
  .resource-table tbody th, .resource-table td { display: block; width: 100%; border: 0; padding: 0.45rem 1rem; }
  .resource-table tbody th { padding-top: 0.85rem; }
  .resource-table td:last-child { padding-bottom: 0.85rem; }
}
@media (forced-colors: active) {
  :root { --canvas: Canvas; --surface: Canvas; --text: CanvasText; --muted: CanvasText; --line: CanvasText; --ok: LinkText; --warn: LinkText; --bad: LinkText; --focus: Highlight; }
  .resource-table, .cleanup, .diagnostics { border: 1px solid CanvasText; }
}
@media print {
  :root { color-scheme: light; --canvas: #fff; --surface: #fff; --text: #000; --muted: #333; --line: #999; }
  body { max-width: none; padding: 0; }
  .cleanup, .diagnostics { border: 1px solid #999; }
}
</style>
</head>
<body>
<main>
<h1 tabindex="-1">Monitor de recursos de Windows</h1>
<p class="meta"><time datetime="$(ConvertTo-HtmlText $report.timestampUtc)">$(ConvertTo-HtmlText $localTimeText)</time> (hora local) - <time datetime="$(ConvertTo-HtmlText $report.timestampUtc)">$(ConvertTo-HtmlText $report.timestampUtc)</time> UTC</p>
<p class="status $(ConvertTo-HtmlText $statusText)"><span class="label">$(ConvertTo-HtmlText $statusText)</span> Datos: <strong>$staleText</strong></p>
<table class="resource-table">
<caption>Resumen de recursos</caption>
<thead><tr><th scope="col">Recurso</th><th scope="col">Estado</th><th scope="col">Valor</th></tr></thead>
<tbody>
<tr><th scope="row">RAM</th><td>$(ConvertTo-HtmlText $ramStatus)</td><td class="value">$ram<br><small>Disponible $(if ($null -ne $ramAvailableGiB) { $ramAvailableGiB } else { 'dato ausente' }) GiB de $(if ($null -ne $ramTotalGiB) { $ramTotalGiB } else { 'dato ausente' }) GiB</small></td></tr>
<tr><th scope="row">CPU</th><td>$(ConvertTo-HtmlText $cpuStatus)</td><td class="value">$cpu</td></tr>
<tr><th scope="row">Disco: $(ConvertTo-HtmlText $report.collectors.disk.systemVolume)</th><td>$(ConvertTo-HtmlText $diskStatus)</td><td class="value">$disk<br><small>Libre $(if ($null -ne $diskFreeGiB) { $diskFreeGiB } else { 'dato ausente' }) GiB de $(if ($null -ne $diskTotalGiB) { $diskTotalGiB } else { 'dato ausente' }) GiB</small></td></tr>
</tbody>
</table>
<h2>Limpieza</h2>
<div class="cleanup">
<p>Activada: <strong>$(if ([bool]$report.cleanup.enabled) {'sí'} else {'no'})</strong> - Estado: $(ConvertTo-HtmlText $report.cleanup.mode).</p>
<p>Elegibles: $(ConvertTo-HtmlText $report.cleanup.eligible); eliminados: $(ConvertTo-HtmlText $report.cleanup.deleted); omitidos: $(ConvertTo-HtmlText $report.cleanup.omitted); fallidos: $(ConvertTo-HtmlText $report.cleanup.failed).</p>
</div>
<h2>Diagnóstico</h2>
<div class="diagnostics">
<ul>
$(@($report.diagnosticIds | ForEach-Object { '<li>' + (ConvertTo-HtmlText $_) + '</li>' }) -join "`n")
</ul>
</div>
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
