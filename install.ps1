# ==============================================================================
# Script: install.ps1 (Windows remote installer)
# Usage:  irm https://raw.githubusercontent.com/RunhuaHuang/EasySkills/main/install.ps1 | iex
# ==============================================================================

$ErrorActionPreference = "Stop"

$Repo = "RunhuaHuang/EasySkills"
$Branch = "main"
$PermDir = "$env:USERPROFILE\EasySkills"
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "EasySkills-install-$(Get-Random)"

function Cleanup { if (Test-Path $TmpDir) { Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue } }

try {
  Write-Host "=============================================" -ForegroundColor Cyan
  Write-Host "EasySkills Remote Installer (Windows)" -ForegroundColor Cyan
  Write-Host "=============================================" -ForegroundColor Cyan

  # --- Download ---
  Write-Host "Downloading EasySkills..."
  New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
  $ZipUrl = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
  $ZipPath = Join-Path $TmpDir "repo.zip"
  Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing
  Expand-Archive -Path $ZipPath -DestinationPath $TmpDir -Force
  $SrcDir = Join-Path $TmpDir "EasySkills-$Branch"

  # --- Install ---
  if (!(Test-Path $PermDir)) { New-Item -ItemType Directory -Path $PermDir -Force | Out-Null }

  # Preserve old version for upgrade reporting
  $OldVersion = $null
  $VersionFile = Join-Path $PermDir "_maintenance\.version"
  if (Test-Path $VersionFile) { $OldVersion = (Get-Content $VersionFile -Raw).Trim() }

  # Migrate custom-targets.txt from old _maintenance/ location to root
  $LegacyCT = Join-Path $PermDir "_maintenance\custom-targets.txt"
  $RootCT = Join-Path $PermDir "custom-targets.txt"
  if (Test-Path $LegacyCT) {
    $Lines = Get-Content $LegacyCT | Where-Object { $_ -and !$_.TrimStart().StartsWith("#") }
    if ($Lines) {
      if (!(Test-Path $RootCT)) { New-Item -ItemType File -Path $RootCT -Force | Out-Null }
      $Existing = @(Get-Content $RootCT -ErrorAction SilentlyContinue)
      foreach ($Line in $Lines) {
        if ($Existing -notcontains $Line) { Add-Content -Path $RootCT -Value $Line }
      }
      Write-Host "Migrated custom targets to $RootCT"
    }
  }

  # Clean install of _maintenance/
  $MaintDir = Join-Path $PermDir "_maintenance"
  if (Test-Path $MaintDir) { Remove-Item $MaintDir -Recurse -Force }
  Copy-Item -Path (Join-Path $SrcDir "_maintenance") -Destination $MaintDir -Recurse
  Copy-Item -Path (Join-Path $SrcDir "SKILL.md") -Destination (Join-Path $MaintDir "SKILL.md") -Force

  # Initialize custom-targets.txt at root if not present
  if (!(Test-Path $RootCT)) {
    $TemplateCT = Join-Path $MaintDir "custom-targets.txt"
    if (Test-Path $TemplateCT) { Copy-Item $TemplateCT $RootCT }
  }

  # Version reporting
  $NewVersion = "unknown"
  $NewVersionFile = Join-Path $MaintDir ".version"
  if (Test-Path $NewVersionFile) { $NewVersion = (Get-Content $NewVersionFile -Raw).Trim() }
  if ($OldVersion -and $OldVersion -ne $NewVersion) {
    Write-Host "Upgraded: $OldVersion -> $NewVersion" -ForegroundColor Green
  } else {
    Write-Host "Installed version: $NewVersion" -ForegroundColor Green
  }

  # --- Activate ---
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $MaintDir "watch.ps1")

  Write-Host "=============================================" -ForegroundColor Cyan
  Write-Host "EasySkills installed successfully!" -ForegroundColor Green
  Write-Host "Drop your custom skills into: $PermDir" -ForegroundColor Green
  Write-Host "=============================================" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "NOTE: If Windows Defender shows a warning, you can add an exclusion:" -ForegroundColor Yellow
  Write-Host "  Add-MpPreference -ExclusionPath `"$PermDir`"" -ForegroundColor Gray

} finally {
  Cleanup
}
