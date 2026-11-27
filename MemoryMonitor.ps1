[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Report', 'Simulate', 'Clean')]
    [string]$Mode = 'Report',
    [switch]$Automatic,
    [switch]$CleanupEnabled
)

$ErrorActionPreference = 'Stop'
$script:ProjectRoot = $PSScriptRoot
$script:ConfigPath = Join-Path $script:ProjectRoot 'MemoryMonitor.config.json'

function Get-MonitorConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $script:ConfigPath"
    }
    $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
    if ($null -eq $config.PSObject.Properties['CleanupEnabled']) {
        $config | Add-Member -NotePropertyName CleanupEnabled -NotePropertyValue $false
    }
    if ($null -eq $config.PSObject.Properties['CleanupRootName']) {
        $config | Add-Member -NotePropertyName CleanupRootName -NotePropertyValue 'WindowsMemoryMonitor'
    }
    if ($null -eq $config.PSObject.Properties['StaleAfterMinutes']) {
        $config | Add-Member -NotePropertyName StaleAfterMinutes -NotePropertyValue 150
    }
    $defaults = @{
        CleanupInspectedLimit = 500
        CleanupDeletedLimit = 100
        CleanupSizeLimitBytes = 268435456
        CleanupBudgetSeconds = 10
    }
    foreach ($key in $defaults.Keys) {
        if ($null -eq $config.PSObject.Properties[$key]) {
            $config | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
        }
    }
    $config
}

function ConvertTo-Gigabytes {
    param([double]$Bytes)
    [math]::Round($Bytes / 1GB, 2)
}

function Convert-RamMeasurement {
    param(
        [Parameter(Mandatory = $true)][int64]$TotalVisibleKiB,
        [Parameter(Mandatory = $true)][int64]$AvailableKiB
    )
    if ($TotalVisibleKiB -le 0) { throw 'Total RAM must be positive.' }
    if ($AvailableKiB -lt 0) { throw 'Available memory cannot be negative.' }
    $total = [int64]($TotalVisibleKiB * 1024)
    $available = [int64]($AvailableKiB * 1024)
    if ($available -gt $total) { throw 'Available memory cannot exceed total memory.' }
    $used = [int64]($total - $available)
    [pscustomobject]@{
        TotalBytes = $total
        AvailableBytes = $available
        UsedBytes = $used
        UsedPct = [math]::Round((100.0 * [decimal]$used / [decimal]$total), 1)
    }
}

function Write-AtomicUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Content
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    $tempPath = Join-Path $parent ('.' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllLines($tempPath, $Content, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backupPath = $tempPath + '.bak'
            [IO.File]::Replace($tempPath, $Path, $backupPath)
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            }
        } else {
            [IO.File]::Move($tempPath, $Path)
        }
    } catch [IO.IOException] {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            throw "Could not replace existing file '$Path': $($_.Exception.Message)"
        }
        [IO.File]::Move($tempPath, $Path)
    } catch {
        throw "Could not publish '$Path': $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-NoReparseAncestors {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-PathWithinRoot -Path $Path -Root $fullRoot)) { return $false }
    $current = [IO.Path]::GetFullPath((Split-Path -Parent $Path))
    while ($true) {
        $directory = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($current.TrimEnd('\').Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $current = $parent
    }
}

function Resolve-UserTempRoot {
    $tempPath = [Environment]::GetEnvironmentVariable('TEMP')
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if ([string]::IsNullOrWhiteSpace($tempPath) -or [string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'TEMP or LOCALAPPDATA is empty; the user temp directory cannot be validated.'
    }

    $resolvedTemp = [IO.Path]::GetFullPath($tempPath)
    $expectedTemp = [IO.Path]::GetFullPath((Join-Path $localAppData 'Temp'))
    $resolvedLocalAppData = [IO.Path]::GetFullPath($localAppData)
    if (-not $resolvedTemp.Equals($expectedTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw "TEMP points to an unexpected path ('$resolvedTemp'); expected '$expectedTemp'."
    }
    if (-not (Split-Path -Parent $resolvedTemp).TrimEnd('\').Equals($resolvedLocalAppData.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The temp directory is not a direct child of LOCALAPPDATA.'
    }
    if (-not (Test-Path -LiteralPath $resolvedTemp -PathType Container)) {
        throw "The temp directory does not exist or is inaccessible: $resolvedTemp"
    }

    $rootItem = Get-Item -LiteralPath $resolvedTemp -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The temp directory is a reparse point; cleanup is skipped.'
    }
    $driveRoot = [IO.Path]::GetPathRoot($resolvedTemp)
    if ($resolvedTemp.TrimEnd('\').Equals($driveRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The temp path is a drive root; cleanup is skipped.'
    }
    $resolvedTemp
}

function Resolve-DedicatedCleanupRoot {
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $false)][string]$OverrideRoot
    )
    $rootName = [string]$Config.CleanupRootName
    if ([string]::IsNullOrWhiteSpace($rootName) -or $rootName -match '[\\/:*?"<>|]' -or $rootName.Contains('..')) {
        throw 'CleanupRootName is not a valid directory name.'
    }
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'LOCALAPPDATA is empty; the dedicated directory cannot be resolved.'
    }
    $resolvedLocalAppData = [IO.Path]::GetFullPath($localAppData)
    $root = if ([string]::IsNullOrWhiteSpace($OverrideRoot)) {
        [IO.Path]::GetFullPath((Join-Path $resolvedLocalAppData $rootName))
    } else {
        [IO.Path]::GetFullPath($OverrideRoot)
    }
    $expectedPrefix = $resolvedLocalAppData.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $root.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetDirectoryName($root).Equals([IO.Path]::GetPathRoot($root), [StringComparison]::OrdinalIgnoreCase)) {
        throw "The dedicated directory is outside LOCALAPPDATA: $root"
    }
    if ($root.TrimEnd('\', '/').Equals([IO.Path]::GetPathRoot($root).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A volume root cannot be used as the cleanup directory.'
    }
    if ($root.StartsWith('\\', [StringComparison]::Ordinal) -or $root.StartsWith('//', [StringComparison]::Ordinal)) {
        throw 'Network paths are not allowed.'
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null
    }
    $item = Get-Item -LiteralPath $root -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The dedicated directory is a reparse point.'
    }
    $root
}

function Test-MonitorConfig {
    param([Parameter(Mandatory = $true)][object]$Config)
    $ranges = [ordered]@{
        CpuSampleSeconds = @(1, 30)
        CleanupAgeDays = @(1, 3650)
        LowDiskFreePercent = @(0, 100)
        RamAlertPercent = @(0, 100)
        DiskAlertPercent = @(0, 100)
        PersistentRuns = @(2, 168)
        HistoryRetentionDays = @(1, 3650)
        HistoryMaxBytes = @(1024, 1073741824)
        HistoryRotations = @(1, 100)
        CleanupInspectedLimit = @(1, 100000)
        CleanupDeletedLimit = @(1, 10000)
        CleanupSizeLimitBytes = @(1, 1099511627776)
        CleanupBudgetSeconds = @(1, 300)
        StaleAfterMinutes = @(1, 10080)
    }
    foreach ($key in $ranges.Keys) {
        if ($null -eq $Config.PSObject.Properties[$key]) { throw "Missing configuration value '$key'." }
        $value = [long]$Config.$key
        if ($value -lt $ranges[$key][0] -or $value -gt $ranges[$key][1]) {
            throw "Configuration value '$key' is out of range: $value."
        }
    }
    if ($null -eq $Config.PSObject.Properties['CleanupEnabled'] -or
        $Config.CleanupEnabled -isnot [bool]) {
        throw 'CleanupEnabled must be a Boolean.'
    }
}

function Test-ProtectedTempPath {
    param([string]$RelativePath)
    $parts = @($RelativePath -split '[\\/]')
    foreach ($part in $parts) {
        if ($part -match '(?i)^(cache|caches|cachestorage|code cache|gpucache|shadercache|dawncache|browser|browsers|chrome|chromium|edge|firefox|opera|brave|vivaldi|safari|downloads|download|recycle\.bin|system volume information|packages)$' -or
            $part -match '(?i)(^|[-_. ])cache(s|storage)?($|[-_. ])') {
            return $true
        }
    }
    $false
}

function Get-EligibleTempFiles {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$AuthorizedRoot,
        [Parameter(Mandatory = $true)][int]$AgeDays,
        [int]$InspectedLimit = 500,
        [int]$BudgetSeconds = 10
    )
    if ($AgeDays -lt 1) { throw 'The minimum file age must be at least one day.' }
    if ($InspectedLimit -lt 1 -or $BudgetSeconds -lt 1) { throw 'Inspection limits must be positive.' }
    $root = [IO.Path]::GetFullPath($RootPath)
    $authorized = [IO.Path]::GetFullPath($AuthorizedRoot)
    if (-not $root.Equals($authorized, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path rejected: '$root' does not exactly match the authorized temp directory '$authorized'."
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "The authorized directory does not exist or is inaccessible: $root"
    }
    $rootInfo = Get-Item -LiteralPath $root -Force
    if (($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The authorized directory is a reparse point.'
    }

    $cutoff = (Get-Date).AddDays(-$AgeDays)
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($root)
    $eligible = New-Object 'System.Collections.Generic.List[object]'
    $skipped = 0
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $inspected = 0
    $budgetReached = $false
    $budgetWatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stack.Count -gt 0) {
        if ($budgetReached) { break }
        if ($inspected -ge $InspectedLimit -or $budgetWatch.Elapsed.TotalSeconds -ge $BudgetSeconds) {
            $budgetReached = $true
            break
        }
        $directory = $stack.Pop()
        try {
            $entries = [IO.Directory]::GetFileSystemEntries($directory)
        } catch {
            $skipped++
            $errors.Add("Could not enumerate '$directory': $($_.Exception.Message)")
            continue
        }
        foreach ($entry in $entries) {
            $inspected++
            if ($inspected -gt $InspectedLimit -or $budgetWatch.Elapsed.TotalSeconds -ge $BudgetSeconds) {
                $budgetReached = $true
                break
            }
            try {
                if (-not (Test-PathWithinRoot -Path $entry -Root $root)) {
                    $skipped++
                    $errors.Add("Entry outside the root was skipped: $entry")
                    continue
                }
                $attributes = [IO.File]::GetAttributes($entry)
                $relative = $entry.Substring($root.Length).TrimStart('\', '/')
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $skipped++
                    continue
                }
                if (($attributes -band [IO.FileAttributes]::System) -ne 0) {
                    $skipped++
                    continue
                }
                if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    if (-not (Test-ProtectedTempPath -RelativePath $relative)) {
                        $stack.Push($entry)
                    } else {
                        $skipped++
                    }
                    continue
                }
                if (Test-ProtectedTempPath -RelativePath $relative) {
                    $skipped++
                    continue
                }
                $fileInfo = New-Object IO.FileInfo($entry)
                if ($fileInfo.LastWriteTime -le $cutoff) {
                    $eligible.Add([pscustomobject]@{
                        Path = $entry
                        Length = [long]$fileInfo.Length
                    })
                }
            } catch {
                $skipped++
                $errors.Add("Could not inspect '$entry': $($_.Exception.Message)")
            }
        }
    }
    [pscustomobject]@{
        Files = @($eligible.ToArray())
        Count = $eligible.Count
        Bytes = [long](($eligible | Measure-Object -Property Length -Sum).Sum)
        Skipped = $skipped
        Errors = @($errors.ToArray())
        Inspected = $inspected
        BudgetReached = $budgetReached
    }
}

function Invoke-SafeTempCleanup {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Simulate', 'Clean')][string]$CleanupMode,
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$AuthorizedRoot,
        [Parameter(Mandatory = $true)][int]$AgeDays,
        [int]$InspectedLimit = 500,
        [int]$DeletedLimit = 100,
        [long]$SizeLimitBytes = 268435456,
        [int]$BudgetSeconds = 10
    )
    $scan = Get-EligibleTempFiles -RootPath $RootPath -AuthorizedRoot $AuthorizedRoot -AgeDays $AgeDays -InspectedLimit $InspectedLimit -BudgetSeconds $BudgetSeconds
    $deleted = 0
    $deletedBytes = [long]0
    $skipped = $scan.Skipped
    $errors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($errorMessage in $scan.Errors) { $errors.Add($errorMessage) }

    if ($CleanupMode -eq 'Clean') {
        foreach ($file in $scan.Files) {
            try {
                if ($deleted -ge $DeletedLimit) { throw "Deletion limit reached: $DeletedLimit." }
                if ($deletedBytes + $file.Length -gt $SizeLimitBytes) { throw "Logical size limit reached: $SizeLimitBytes bytes." }
                if (-not (Test-PathWithinRoot -Path $file.Path -Root $AuthorizedRoot)) {
                    throw "Path is outside the authorized directory: $($file.Path)"
                }
                if (-not (Test-NoReparseAncestors -Path $file.Path -Root $AuthorizedRoot)) {
                    throw 'The file is under a reparse point or an untrusted path.'
                }
                $attributes = [IO.File]::GetAttributes($file.Path)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    ($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    throw 'The item is no longer a regular file.'
                }
                $currentInfo = New-Object IO.FileInfo($file.Path)
                if ($currentInfo.LastWriteTime -gt (Get-Date).AddDays(-$AgeDays)) {
                    throw 'The file no longer meets the minimum age.'
                }
                [IO.File]::Delete($file.Path)
                $deleted++
                $deletedBytes += $file.Length
            } catch {
                $skipped++
                $errors.Add("Skipped '$($file.Path)': $($_.Exception.Message)")
            }
        }
    }

    [pscustomobject]@{
        Mode = $CleanupMode
        Eligible = $scan.Count
        EligibleBytes = $scan.Bytes
        Deleted = $deleted
        DeletedBytes = $deletedBytes
        Skipped = $skipped
        Errors = @($errors.ToArray())
        Inspected = $scan.Inspected
        BudgetReached = $scan.BudgetReached
    }
}

function Get-SystemMetrics {
    param([int]$CpuSampleSeconds)
    $metrics = [ordered]@{
        RamTotalBytes = $null; RamAvailableBytes = $null; RamUsedBytes = $null; RamUsedPercent = $null
        CpuPercent = $null; CpuTopProcesses = @(); DiskTotalBytes = $null; DiskFreeBytes = $null; DiskFreePercent = $null
        Errors = New-Object 'System.Collections.Generic.List[string]'
    }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $ram = Convert-RamMeasurement -TotalVisibleKiB ([int64]$os.TotalVisibleMemorySize) -AvailableKiB ([int64]$os.FreePhysicalMemory)
        $metrics.RamTotalBytes = $ram.TotalBytes
        $metrics.RamAvailableBytes = $ram.AvailableBytes
        $metrics.RamUsedBytes = $ram.UsedBytes
        $metrics.RamUsedPercent = $ram.UsedPct
    } catch { $metrics.Errors.Add("RAM: $($_.Exception.Message)") }

    try {
        $before = @{}
        foreach ($process in Get-Process -ErrorAction Stop) {
            try {
                $before[[int]$process.Id] = [pscustomobject]@{
                    Name = $process.ProcessName
                    Cpu = [double]$process.TotalProcessorTime.TotalSeconds
                    Start = $process.StartTime
                }
            } catch {}
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Seconds $CpuSampleSeconds
        $watch.Stop()
        $deltas = New-Object 'System.Collections.Generic.List[object]'
        $totalCpuSeconds = [double]0
        foreach ($process in Get-Process -ErrorAction Stop) {
            try {
                $id = [int]$process.Id
                if (-not $before.ContainsKey($id)) { continue }
                $old = $before[$id]
                if ($process.StartTime -ne $old.Start) { continue }
                $delta = [double]$process.TotalProcessorTime.TotalSeconds - $old.Cpu
                if ($delta -lt 0) { continue }
                $totalCpuSeconds += $delta
                if ($delta -gt 0) {
                    $deltas.Add([pscustomobject]@{
                        Name = $process.ProcessName
                        Id = $id
                        CpuPercent = [math]::Round(100 * $delta / ($watch.Elapsed.TotalSeconds * [Environment]::ProcessorCount), 1)
                    })
                }
            } catch {}
        }
        $metrics.CpuPercent = [math]::Round(100 * $totalCpuSeconds / ($watch.Elapsed.TotalSeconds * [Environment]::ProcessorCount), 1)
        $metrics.CpuTopProcesses = @($deltas | Sort-Object CpuPercent -Descending | Select-Object -First 5)
    } catch { $metrics.Errors.Add("CPU: $($_.Exception.Message)") }

    try {
        $systemDrive = [IO.Path]::GetPathRoot($env:SystemDrive)
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $systemDrive.TrimEnd('\') + "'") -ErrorAction Stop
        if (-not $disk -or [double]$disk.Size -le 0) { throw 'Could not retrieve the system volume size.' }
        $metrics.DiskTotalBytes = [double]$disk.Size
        $metrics.DiskFreeBytes = [double]$disk.FreeSpace
        $metrics.DiskFreePercent = [math]::Round(100 * $metrics.DiskFreeBytes / $metrics.DiskTotalBytes, 1)
    } catch { $metrics.Errors.Add("Disco: $($_.Exception.Message)") }

    $processes = @()
    try {
        $processes = @(Get-Process -ErrorAction Stop | ForEach-Object {
            try {
                [pscustomobject]@{ Name = $_.ProcessName; Id = [int]$_.Id; Bytes = [long]$_.WorkingSet64 }
            } catch {}
        } | Where-Object { $null -ne $_ })
    } catch { $metrics.Errors.Add("Procesos/RAM residente: $($_.Exception.Message)") }
    $metrics | Add-Member -NotePropertyName TopMemoryProcesses -NotePropertyValue @($processes | Sort-Object @{Expression='Bytes';Descending=$true}, @{Expression='Name';Descending=$false}, @{Expression='Id';Descending=$false} | Select-Object -First 5)
    $metrics | Add-Member -NotePropertyName GroupedMemoryProcesses -NotePropertyValue @(
        $processes | Group-Object Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Instances = $_.Count; Bytes = [long](($_.Group | Measure-Object Bytes -Sum).Sum) }
        } | Sort-Object Bytes -Descending | Select-Object -First 5
    )
    $metrics
}

function Get-RecentHistory {
    param([string]$Path, [int]$Count)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $sources = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Filter 'history-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $sources += Get-Item -LiteralPath $Path }
    foreach ($source in $sources) {
        foreach ($line in Get-Content -LiteralPath $source.FullName -ErrorAction Stop) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $items.Add(($line | ConvertFrom-Json -ErrorAction Stop)) }
            catch { Write-Warning "Ignored an invalid history line: $($_.Exception.Message)" }
        }
    }
    @($items.ToArray() | Sort-Object Timestamp | Select-Object -Last $Count)
}

function Write-HistoryRecord {
    param([string]$Path, [object]$Record, [object]$Config)
    $cutoff = (Get-Date).AddDays(-[int]$Config.HistoryRetentionDays)
    foreach ($oldFile in @(Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Filter 'history-*.jsonl' -File -ErrorAction SilentlyContinue)) {
        if ($oldFile.LastWriteTime -lt $cutoff) { Remove-Item -LiteralPath $oldFile.FullName -Force -ErrorAction SilentlyContinue }
    }
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge [long]$Config.HistoryMaxBytes) {
        for ($i = [int]$Config.HistoryRotations; $i -ge 1; $i--) {
            $destination = Join-Path (Split-Path -Parent $Path) ("history-{0}.jsonl" -f $i)
            $source = if ($i -eq 1) { $Path } else { Join-Path (Split-Path -Parent $Path) ("history-{0}.jsonl" -f ($i - 1)) }
            if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
            if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination $destination -Force }
        }
    }
    $json = ConvertTo-Json -InputObject $Record -Depth 8 -Compress
    Add-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Format-ProcessRows {
    param([object[]]$Processes, [string]$Kind)
    if (-not $Processes -or $Processes.Count -eq 0) { return "_Unavailable._" }
    if ($Kind -eq 'Memory') {
        return (@($Processes | ForEach-Object { '| {0} | {1} | {2:N2} GB |' -f $_.Name, $_.Id, ($_.Bytes / 1GB) }) -join "`n")
    }
    return (@($Processes | ForEach-Object { '| {0} | {1} | {2:N1}% |' -f $_.Name, $_.Id, $_.CpuPercent }) -join "`n")
}

function Send-PersistentAlertToast {
    param([string]$Message)
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>Monitor de recursos de Windows</text><text>$([Security.SecurityElement]::Escape($Message))</text></binding></visual></toast>")
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Windows PowerShell').Show($toast)
    } catch {
        Write-Warning "Could not display the Windows notification: $($_.Exception.Message)"
    }
}

function Invoke-Monitor {
    param([string]$RunMode, [bool]$IsAutomatic)
    $config = Get-MonitorConfig
    Test-MonitorConfig -Config $config
    $cleanupEnabled = [bool]$config.CleanupEnabled
    $outputDir = Join-Path $script:ProjectRoot 'reports'
    if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $lockPath = Join-Path $outputDir 'run.lock'
    $lock = $null
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        Write-Output 'Another run is already in progress; this run was skipped.'
        return
    }

    try {
        $started = Get-Date
        $metrics = Get-SystemMetrics -CpuSampleSeconds ([int]$config.CpuSampleSeconds)
        $historyPath = Join-Path $outputDir 'history.jsonl'
        $prior = @(Get-RecentHistory -Path $historyPath -Count ([int]$config.PersistentRuns - 1))
        $ramAlert = ($null -ne $metrics.RamUsedPercent -and $metrics.RamUsedPercent -ge [double]$config.RamAlertPercent)
        $diskAlert = ($null -ne $metrics.DiskFreePercent -and $metrics.DiskFreePercent -le [double]$config.DiskAlertPercent)
        $priorRamAlerts = 0
        $priorDiskAlerts = 0
        for ($i = $prior.Count - 1; $i -ge 0; $i--) {
            if ($prior[$i].RamAlert) { $priorRamAlerts++ } else { break }
        }
        for ($i = $prior.Count - 1; $i -ge 0; $i--) {
            if ($prior[$i].DiskAlert) { $priorDiskAlerts++ } else { break }
        }
        $ramPersistent = $ramAlert -and ($priorRamAlerts + 1 -ge [int]$config.PersistentRuns)
        $diskPersistent = $diskAlert -and ($priorDiskAlerts + 1 -ge [int]$config.PersistentRuns)

        $cleanup = $null
        $cleanupMessage = 'Not run (report-only mode).'
        if ($RunMode -ne 'Report') {
            try {
                $cleanupEnabled = [bool]$config.CleanupEnabled -or [bool]$CleanupEnabled
                $cleanupRoot = Resolve-DedicatedCleanupRoot -Config $config
                if (-not $cleanupEnabled) {
                    $cleanupMessage = 'Cleanup blocked: explicit opt-in is required. Only the report was generated.'
                    $cleanup = [pscustomobject]@{
                        Mode = 'Blocked'; Eligible = 0; EligibleBytes = [long]0; Deleted = 0
                        DeletedBytes = [long]0; Skipped = 0; Errors = @('CLEANUP_NOT_ENABLED')
                    }
                } elseif ($IsAutomatic) {
                    $preview = Invoke-SafeTempCleanup -CleanupMode Simulate -RootPath $cleanupRoot -AuthorizedRoot $cleanupRoot -AgeDays ([int]$config.CleanupAgeDays) -InspectedLimit ([int]$config.CleanupInspectedLimit) -DeletedLimit ([int]$config.CleanupDeletedLimit) -SizeLimitBytes ([long]$config.CleanupSizeLimitBytes) -BudgetSeconds ([int]$config.CleanupBudgetSeconds)
                    $statePath = Join-Path $outputDir 'state.json'
                    $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { [pscustomobject]@{ LastAutomaticCleanupDate = '' } }
                    $today = (Get-Date).ToString('yyyy-MM-dd')
                    $diskLow = ($null -ne $metrics.DiskFreePercent -and $metrics.DiskFreePercent -le [double]$config.LowDiskFreePercent)
                    $tempLarge = $preview.EligibleBytes -ge [long]$config.CleanupTempBytesThreshold
                    if ($preview.Eligible -gt 0 -and ($diskLow -or $tempLarge) -and $state.LastAutomaticCleanupDate -ne $today) {
                        $state.LastAutomaticCleanupDate = $today
                        $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
                        $cleanup = Invoke-SafeTempCleanup -CleanupMode Clean -RootPath $cleanupRoot -AuthorizedRoot $cleanupRoot -AgeDays ([int]$config.CleanupAgeDays) -InspectedLimit ([int]$config.CleanupInspectedLimit) -DeletedLimit ([int]$config.CleanupDeletedLimit) -SizeLimitBytes ([long]$config.CleanupSizeLimitBytes) -BudgetSeconds ([int]$config.CleanupBudgetSeconds)
                        $cleanupMessage = "Automatic cleanup: deleted $($cleanup.Deleted) file(s), skipped $($cleanup.Skipped); estimated logical size removed $([math]::Round($cleanup.DeletedBytes / 1MB, 2)) MB."
                    } else {
                        $cleanupMessage = "Automatic cleanup not triggered; eligible: $($preview.Eligible) file(s), $([math]::Round($preview.EligibleBytes / 1MB, 2)) MB. Daily threshold: $([math]::Round([long]$config.CleanupTempBytesThreshold / 1GB, 2)) GB or disk free <= $($config.LowDiskFreePercent)%."
                        if ($state.LastAutomaticCleanupDate -eq $today) { $cleanupMessage += ' Cleanup was already attempted today.' }
                    }
                } else {
                    $effectiveCleanupMode = if ($WhatIfPreference -and $RunMode -eq 'Clean') { 'Simulate' } else { $RunMode }
                    $cleanup = Invoke-SafeTempCleanup -CleanupMode $effectiveCleanupMode -RootPath $cleanupRoot -AuthorizedRoot $cleanupRoot -AgeDays ([int]$config.CleanupAgeDays) -InspectedLimit ([int]$config.CleanupInspectedLimit) -DeletedLimit ([int]$config.CleanupDeletedLimit) -SizeLimitBytes ([long]$config.CleanupSizeLimitBytes) -BudgetSeconds ([int]$config.CleanupBudgetSeconds)
                    if ($RunMode -eq 'Simulate') {
                        $cleanupMessage = "Simulation: $($cleanup.Eligible) eligible file(s), total size $([math]::Round($cleanup.EligibleBytes / 1MB, 2)) MB; deleted 0, skipped $($cleanup.Skipped)."
                    } else {
                        $cleanupMessage = "Cleanup: $($cleanup.Eligible) eligible, $($cleanup.Deleted) deleted, $($cleanup.Skipped) skipped; estimated logical size removed $([math]::Round($cleanup.DeletedBytes / 1MB, 2)) MB."
                    }
                }
            } catch {
                $cleanupMessage = "Cleanup skipped: $($_.Exception.Message)"
                if ($null -eq $cleanup) {
                    $cleanup = [pscustomobject]@{ Mode = $RunMode; Eligible = $null; EligibleBytes = $null; Deleted = 0; DeletedBytes = 0; Skipped = 0; Errors = @($_.Exception.Message) }
                }
            }
        }

        $recommendations = New-Object 'System.Collections.Generic.List[string]'
        if ($null -ne $metrics.RamUsedPercent) {
            if ($ramPersistent) { $recommendations.Add("RAM exceeded $($config.RamAlertPercent)% for at least $($config.PersistentRuns) consecutive runs. Review the listed applications and save your work before closing anything.") }
            elseif ($ramAlert) { $recommendations.Add('RAM usage is high in this sample; check whether it persists before taking action.') }
            else { $recommendations.Add('RAM usage is below the configured threshold.') }
        }
        if ($null -ne $metrics.DiskFreePercent) {
            if ($diskPersistent) { $recommendations.Add("Free disk space was below $($config.DiskAlertPercent)% for at least $($config.PersistentRuns) consecutive runs. Review large files and backups; do not delete system files.") }
            elseif ($diskAlert) { $recommendations.Add('Free disk space is low in this sample; check whether the condition persists.') }
            else { $recommendations.Add('Free disk space is above the configured threshold.') }
        }
        if ($null -ne $metrics.CpuPercent -and $metrics.CpuPercent -ge 80) { $recommendations.Add('CPU utilization was high during the sample; review the listed processes and sample again to check whether the load is temporary.') }
        if ($cleanup -and $cleanup.Eligible -gt 0) { $recommendations.Add("$($cleanup.Eligible) old temporary file(s) were found. Cleanup is confined to the validated dedicated directory.") }
        if ($recommendations.Count -eq 0) { $recommendations.Add('There is not enough metric data for specific recommendations; review the reported errors.') }

        $record = [pscustomobject]@{
            schemaVersion = 1
            TimestampUtc = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            Timestamp = $started.ToString('o')
            RamUsedPercent = $metrics.RamUsedPercent
            DiskFreePercent = $metrics.DiskFreePercent
            CpuPercent = $metrics.CpuPercent
            RamAlert = [bool]$ramAlert
            DiskAlert = [bool]$diskAlert
            RamPersistent = [bool]$ramPersistent
            DiskPersistent = [bool]$diskPersistent
            CleanupMode = if ($cleanup) { $cleanup.Mode } else { $RunMode }
            CleanupEligible = if ($cleanup) { $cleanup.Eligible } else { $null }
            CleanupDeleted = if ($cleanup) { $cleanup.Deleted } else { 0 }
            CleanupDeletedBytes = if ($cleanup) { $cleanup.DeletedBytes } else { 0 }
            CleanupSkipped = if ($cleanup) { $cleanup.Skipped } else { 0 }
        }
        Write-HistoryRecord -Path $historyPath -Record $record -Config $config

        $lines = New-Object 'System.Collections.Generic.List[string]'
        $lines.Add('# Monitor de recursos de Windows')
        $lines.Add('')
        $lines.Add("Local date and time: $($started.ToString('yyyy-MM-dd HH:mm:ss zzz'))")
        $lines.Add('')
        $lines.Add('## RAM')
        if ($null -ne $metrics.RamTotalBytes) {
            $lines.Add(('- Total: {0:N2} GB; available: {1:N2} GB; used: {2:N2} GB ({3:N1}%).' -f (ConvertTo-Gigabytes $metrics.RamTotalBytes), (ConvertTo-Gigabytes $metrics.RamAvailableBytes), (ConvertTo-Gigabytes $metrics.RamUsedBytes), $metrics.RamUsedPercent))
            $lines.Add('')
            $lines.Add('| Process | PID | Resident memory |')
            $lines.Add('|---|---:|---:|')
            $lines.Add((Format-ProcessRows -Processes $metrics.TopMemoryProcesses -Kind Memory))
            $lines.Add('')
            $lines.Add('### Applications grouped by memory usage')
            foreach ($group in $metrics.GroupedMemoryProcesses) { $lines.Add(('- {0}: {1} instancia(s), {2:N2} GB.' -f $group.Name, $group.Instances, ($group.Bytes / 1GB))) }
        } else { $lines.Add('- Unavailable.') }
        $lines.Add('')
        $lines.Add('## CPU and disk')
        if ($null -ne $metrics.CpuPercent) {
            $lines.Add(('- Average CPU over {0} s: {1:N1}% of total logical processor capacity.' -f $config.CpuSampleSeconds, $metrics.CpuPercent))
            $lines.Add('')
            $lines.Add('| Process | PID | CPU during sample |')
            $lines.Add('|---|---:|---:|')
            $lines.Add((Format-ProcessRows -Processes $metrics.CpuTopProcesses -Kind CPU))
        } else { $lines.Add('- CPU: unavailable.') }
        if ($null -ne $metrics.DiskTotalBytes) {
            $lines.Add(('- System volume: {0:N2} GB free of {1:N2} GB ({2:N1}% free).' -f (ConvertTo-Gigabytes $metrics.DiskFreeBytes), (ConvertTo-Gigabytes $metrics.DiskTotalBytes), $metrics.DiskFreePercent))
        } else { $lines.Add('- Disk: unavailable.') }
        $lines.Add('')
        $lines.Add('## Cleanup')
        $lines.Add($cleanupMessage)
        if ($cleanup -and $cleanup.Mode -eq 'Simulate') {
            $lines.Add("Eligible files: $($cleanup.Eligible); total size: $([math]::Round($cleanup.EligibleBytes / 1MB, 2)) MB. Simulation: no files were deleted.")
        } elseif ($cleanup) {
            $lines.Add("Deleted files: $($cleanup.Deleted); skipped: $($cleanup.Skipped); estimated logical size removed: $([math]::Round($cleanup.DeletedBytes / 1MB, 2)) MB. This estimate sums file sizes and does not measure actual disk space reclaimed.")
        }
        $lines.Add('')
        $lines.Add('## Trends and recommendations')
        $lines.Add("- Configured alerts: RAM >= $($config.RamAlertPercent)%; free disk <= $($config.DiskAlertPercent)%; persistence: $($config.PersistentRuns) consecutive runs.")
        foreach ($recommendation in $recommendations) { $lines.Add("- $recommendation") }
        if ($metrics.Errors.Count -gt 0) {
            $lines.Add('')
            $lines.Add('## Unavailable metrics / errors')
            foreach ($metricError in $metrics.Errors) { $lines.Add("- $metricError") }
        }
        if ($cleanup -and $cleanup.Errors.Count -gt 0) {
            $lines.Add('')
            $lines.Add('## Skipped items / cleanup errors')
            foreach ($cleanupError in $cleanup.Errors) { $lines.Add("- $cleanupError") }
        }
        $reportPath = Join-Path $outputDir 'latest-report.md'
        if ($prior.Count -gt 0) {
            $previous = $prior[$prior.Count - 1]
            $trendIndex = $lines.IndexOf('## Tendencia y recomendaciones')
            $lines.Insert($trendIndex, '## Comparison with previous run')
            if ($null -ne $metrics.RamUsedPercent -and $null -ne $previous.RamUsedPercent) {
                $lines.Insert($trendIndex + 1, ('- RAM used: {0:N1}% vs {1:N1}% (change {2:+0.0;-0.0;0.0} points).' -f $metrics.RamUsedPercent, $previous.RamUsedPercent, ($metrics.RamUsedPercent - $previous.RamUsedPercent)))
                $trendIndex++
            }
            if ($null -ne $metrics.CpuPercent -and $null -ne $previous.CpuPercent) {
                $lines.Insert($trendIndex + 1, ('- Average CPU: {0:N1}% vs {1:N1}% (change {2:+0.0;-0.0;0.0} points).' -f $metrics.CpuPercent, $previous.CpuPercent, ($metrics.CpuPercent - $previous.CpuPercent)))
                $trendIndex++
            }
            if ($null -ne $metrics.DiskFreePercent -and $null -ne $previous.DiskFreePercent) {
                $lines.Insert($trendIndex + 1, ('- Free disk: {0:N1}% vs {1:N1}% (change {2:+0.0;-0.0;0.0} points).' -f $metrics.DiskFreePercent, $previous.DiskFreePercent, ($metrics.DiskFreePercent - $previous.DiskFreePercent)))
                $trendIndex++
            }
            if ($ramAlert -and -not $ramPersistent) { $lines.Insert($trendIndex + 1, '- The RAM alert has not reached the configured consecutive-run count; treat it as a possible isolated spike for now.') }
            if ($diskAlert -and -not $diskPersistent) { $lines.Insert($trendIndex + 1, '- The disk alert has not reached the configured consecutive-run count; check whether it persists.') }
            $lines.Insert($trendIndex + 2, '')
        } else {
            $trendIndex = $lines.IndexOf('## Tendencia y recomendaciones')
            $lines.Insert($trendIndex, '## Comparison with previous runs')
            $lines.Insert($trendIndex + 1, '- No previous runs are available for comparison.')
            $lines.Insert($trendIndex + 2, '')
        }
        Write-AtomicUtf8File -Path $reportPath -Content $lines.ToArray()

        $jsonPath = Join-Path $outputDir 'latest-report.json'
        $jsonRecord = [pscustomobject]@{
            schemaVersion = 1
            monitorVersion = '4f39414'
            timestampUtc = $record.TimestampUtc
            durationSeconds = [math]::Round((Get-Date).Subtract($started).TotalSeconds, 3)
            status = if ($metrics.Errors.Count -eq 0) { 'ok' } elseif (
                $null -ne $metrics.RamUsedPercent -or $null -ne $metrics.CpuPercent -or $null -ne $metrics.DiskFreeBytes
            ) { 'partial' } else { 'failed' }
            collectors = [pscustomobject]@{
                ram = [pscustomobject]@{ status = if ($null -ne $metrics.RamUsedPercent) { 'ok' } else { 'failed' }; totalBytes = $metrics.RamTotalBytes; availableBytes = $metrics.RamAvailableBytes; usedBytes = $metrics.RamUsedBytes; usedPct = $metrics.RamUsedPercent }
                cpu = [pscustomobject]@{ status = if ($null -ne $metrics.CpuPercent) { 'ok' } else { 'failed' }; usedPct = $metrics.CpuPercent; sampleSeconds = [int]$config.CpuSampleSeconds }
                disk = [pscustomobject]@{ status = if ($null -ne $metrics.DiskFreeBytes) { 'ok' } else { 'failed' }; systemVolume = 'System'; totalBytes = $metrics.DiskTotalBytes; freeBytes = $metrics.DiskFreeBytes; freePct = $metrics.DiskFreePercent }
            }
            cleanup = [pscustomobject]@{
                enabled = [bool]$cleanupEnabled
                mode = if ($cleanup) { [string]$cleanup.Mode } else { [string]$RunMode }
                inspected = if ($cleanup -and $cleanup.PSObject.Properties['Eligible']) { $cleanup.Eligible } else { $null }
                eligible = if ($cleanup) { $cleanup.Eligible } else { $null }
                omitted = if ($cleanup) { $cleanup.Skipped } else { $null }
                deleted = if ($cleanup) { $cleanup.Deleted } else { 0 }
                failed = if ($cleanup -and $cleanup.Errors.Count -gt 0) { $cleanup.Errors.Count } else { 0 }
            }
            alerts = [pscustomobject]@{ ram = [bool]$ramPersistent; disk = [bool]$diskPersistent }
            diagnosticIds = @($metrics.Errors)
            stale = $false
        }
        $jsonText = $jsonRecord | ConvertTo-Json -Depth 8
        Write-AtomicUtf8File -Path $jsonPath -Content @($jsonText)
        $htmlScript = Join-Path $script:ProjectRoot 'Generate-ReportHtml.ps1'
        if (Test-Path -LiteralPath $htmlScript -PathType Leaf) {
            try {
                & $htmlScript -InputJson $jsonPath -OutputHtml (Join-Path $outputDir 'latest-report.html') -StaleAfterMinutes ([int]$config.StaleAfterMinutes) -ErrorAction Stop | Out-Null
            } catch {
                $metrics.Errors.Add("HTML report: $($_.Exception.Message)")
            }
        }

        if ([bool]$config.EnableWindowsNotifications -and ($ramPersistent -or $diskPersistent)) {
            $alertText = @()
            if ($ramPersistent) { $alertText += 'RAM persistentemente alta' }
            if ($diskPersistent) { $alertText += 'disco persistentemente bajo' }
            Send-PersistentAlertToast -Message ($alertText -join '; ')
        }
        Write-Output "Report saved: $reportPath"
        Write-Output $cleanupMessage
        if ($cleanup) {
            Write-Output "Free disk space before: $(if ($null -ne $metrics.DiskFreeBytes) { '{0:N2} GB' -f ($metrics.DiskFreeBytes / 1GB) } else { 'unavailable' })"
            $after = $null
            try {
                $systemDrive = [IO.Path]::GetPathRoot($env:SystemDrive)
                $after = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $systemDrive.TrimEnd('\') + "'") -ErrorAction Stop
            } catch {}
            Write-Output "Free disk space after: $(if ($after) { '{0:N2} GB' -f ([double]$after.FreeSpace / 1GB) } else { 'unavailable' })"
        }
    } finally {
        if ($lock) { $lock.Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Monitor -RunMode $Mode -IsAutomatic ([bool]$Automatic)
}
