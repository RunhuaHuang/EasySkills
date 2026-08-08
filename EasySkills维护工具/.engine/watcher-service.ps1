# ==============================================================================
# Script: watcher-service.ps1 (Windows)
# Description: Background listener using System.IO.FileSystemWatcher.
#              Single-instance via session-local named mutex. Designed to
#              run under Task Scheduler with restart-on-failure.
# ==============================================================================

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
# The engine lives at EasySkills维护工具/.engine (two levels under the install
# root), so CentralDir must go up TWO parents to reach the directory that holds
# the skill folders — the directory this FileSystemWatcher must monitor. A
# single Split-Path would watch EasySkills维护工具\ (only .engine/ inside), so
# skill-folder changes at the root would never trigger a resync.
$CentralDir = Split-Path -Path (Split-Path -Path $ScriptDir -Parent) -Parent
$PromaDir = Join-Path -Path $Home -ChildPath ".proma"
$MutexName = "Local\EasySkillsWatcherService_v2"

$LogDir  = Join-Path $ScriptDir "logs"
$LogFile = Join-Path $LogDir "watcher-service.log"
if (-not (Test-Path $LogDir)) {
    try { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } catch {}
}
function Write-WatcherLog([string]$Message) {
    try {
        $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [pid=$PID] $Message"
        Add-Content -Path $LogFile -Value $Line -Encoding UTF8 -ErrorAction SilentlyContinue
        $Info = Get-Item $LogFile -ErrorAction SilentlyContinue
        if ($Info -and $Info.Length -gt 1048576) {
            $Tail = Get-Content $LogFile -Tail 500 -ErrorAction SilentlyContinue
            if ($Tail) { $Tail | Set-Content -Path $LogFile -Encoding UTF8 }
        }
    } catch {}
}

# --- single-instance guard ---------------------------------------------------
$Mutex = New-Object System.Threading.Mutex($false, $MutexName)
$Acquired = $false
try {
    $Acquired = $Mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $Acquired = $true
}
if (-not $Acquired) {
    Write-WatcherLog "Another watcher-service instance is already running; exiting."
    exit 0
}

Write-WatcherLog "Watcher started. CentralDir=$CentralDir"

# Initial synchronization
try {
    & "$ScriptDir\deploy.ps1"
} catch {
    Write-WatcherLog "Initial sync failed: $($_.Exception.Message)"
}

# FileSystemWatcher is created via a function so it can be torn down and rebuilt
# after an InternalBufferOverflowException (a common occurrence during bulk
# operations like git checkout). Reusing a watcher that overflowed silently
# drops subsequent events, so we dispose + recreate it.
function New-Watcher {
    $w = New-Object System.IO.FileSystemWatcher
    $w.Path = $CentralDir
    $w.IncludeSubdirectories = $true
    $w.InternalBufferSize = 65536  # 64 KiB; max that doesn't hit the 64 KiB ceiling issue
    $w.EnableRaisingEvents = $true
    return $w
}

$Watcher = New-Watcher
Write-Host "[*] Starting background watcher on $CentralDir..."

try {
    # Block and wait for changes forever
    while ($true) {
        try {
            $PromaPollingEnabled = Test-Path $PromaDir
            $WaitTimeout = if ($PromaPollingEnabled) { 300000 } else { 600000 }
            $Change = $Watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, $WaitTimeout)

            if (($Change.TimedOut -eq $false) -or ($PromaPollingEnabled -and $Change.TimedOut)) {
                # Only sync on root-level changes or changes inside the 'instructions' directory.
                # Skip changes inside skill folders.
                $IsRelevant = ($null -eq $Change.Name) -or ($Change.Name -eq "") -or (($Change.Name -notlike "*\*") -and ($Change.Name -notlike "*/*")) -or $Change.Name.ToLower().StartsWith("instructions\") -or $Change.Name.ToLower().StartsWith("instructions/")
                if (-not $IsRelevant) {
                    continue
                }

                # Debounce: drain any further changes that arrived while we were
                # busy, then run a single sync covering the whole burst. The old
                # 500ms sleep fired one deploy per event; this coalesces them.
                # Cap the drain iterations so a non-stop change stream can't
                # starve the deploy indefinitely.
                $DrainIterations = 0
                while ($DrainIterations -lt 20) {
                    $More = $Watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, 500)
                    if ($More.TimedOut) { break }
                    $DrainIterations++
                }
                try {
                    & "$ScriptDir\deploy.ps1"
                } catch {
                    Write-WatcherLog "Sync failed: $($_.Exception.Message)"
                }
            }
        } catch {
            # Buffer overflow or other watcher error: rebuild the watcher so we
            # don't silently miss events on a poisoned instance.
            Write-WatcherLog "Watcher error: $($_.Exception.Message). Rebuilding watcher in 5s..."
            try { $Watcher.Dispose() } catch {}
            Start-Sleep -Seconds 5
            $Watcher = New-Watcher
        }
    }
} finally {
    try { $Watcher.Dispose() } catch {}
    try { $Mutex.ReleaseMutex() } catch {}
    try { $Mutex.Dispose() } catch {}
    Write-WatcherLog "Watcher exiting."
}
