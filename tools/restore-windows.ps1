<#
.SYNOPSIS
  Unpack a Project Vault backup on Windows, and optionally put every file back
  into your projects.

.DESCRIPTION
  Project Vault saves each encrypted backup twice: a .dmg for Macs, and a
  ProjectVault-<date>.tar.gz.enc archive that this script opens on Windows.

  It asks for the backup password (it is not shown or saved), decrypts the
  archive with OpenSSL from Git for Windows, and unpacks it with the tar.exe
  built into Windows 10 and 11. Inside is a _ProjectVault folder: every file is
  in _ProjectVault\current, at the same path it had in your projects folder.

  With -ProjectsFolder it also copies each file back into that folder (into the
  projects you cloned again). Files that already exist are left alone unless
  you add -Overwrite.

  Needs: Windows 10 (1803 or later) or Windows 11, and Git for Windows
  (https://git-scm.com/download/win), which includes OpenSSL.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File restore-windows.ps1 "D:\ProjectVault Backups\ProjectVault-2026-11-23_140400.tar.gz.enc"

  Unpacks into %USERPROFILE%\ProjectVault-restore.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File restore-windows.ps1 "ProjectVault-2026-11-23_140400.tar.gz.enc" -ProjectsFolder C:\code

  Unpacks, then copies every backed-up file to the same path under C:\code
  (for example C:\code\acme\shop-backend\.env).

.LINK
  https://github.com/zamansheikh/project-vault
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string] $Archive,

  # Where to unpack the backup.
  [string] $Destination = (Join-Path $env:USERPROFILE "ProjectVault-restore"),

  # Also copy every file back to the same path under this folder.
  [string] $ProjectsFolder,

  # With -ProjectsFolder: replace files that already exist.
  [switch] $Overwrite
)

$ErrorActionPreference = "Stop"

function Find-OpenSSL {
  $candidates = @(
    (Join-Path $env:ProgramFiles "Git\mingw64\bin\openssl.exe"),
    (Join-Path $env:ProgramFiles "Git\usr\bin\openssl.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Git\mingw64\bin\openssl.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Git\usr\bin\openssl.exe")
  )
  if (${env:ProgramFiles(x86)}) {
    $candidates += (Join-Path ${env:ProgramFiles(x86)} "Git\mingw64\bin\openssl.exe")
  }
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  $cmd = Get-Command openssl.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# ---------- checks ----------
if (-not (Test-Path -LiteralPath $Archive)) { throw "File not found: $Archive" }
$Archive = (Resolve-Path -LiteralPath $Archive).Path
if ($Archive -like "*.dmg") {
  throw "That is the Mac version of the backup. Use the ProjectVault-<date>.tar.gz.enc file next to it."
}
if ($Archive -notlike "*.tar.gz.enc") {
  Write-Warning "Expected a ProjectVault-<date>.tar.gz.enc file; trying anyway."
}

$openssl = Find-OpenSSL
if (-not $openssl) {
  throw "OpenSSL was not found. Install Git for Windows (https://git-scm.com/download/win), then run this again."
}
$tar = Join-Path $env:SystemRoot "System32\tar.exe"
if (-not (Test-Path -LiteralPath $tar)) {
  throw "tar.exe was not found. It comes with Windows 10 (version 1803 or later) and Windows 11."
}

# ---------- decrypt ----------
$secure = Read-Host "Backup password" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("projectvault-" + [Guid]::NewGuid().ToString("N") + ".tar.gz")

# The password reaches OpenSSL through an environment variable that only the
# OpenSSL process gets; it is never on a command line or in a file.
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $openssl
$psi.Arguments = "enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -pass env:PV_BACKUP_PASSWORD -in `"$Archive`" -out `"$tmp`""
$psi.UseShellExecute = $false
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$psi.EnvironmentVariables["PV_BACKUP_PASSWORD"] = $plain
$plain = $null

Write-Host "Decrypting..."
$proc = [Diagnostics.Process]::Start($psi)
$err = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()
$psi.EnvironmentVariables.Remove("PV_BACKUP_PASSWORD")
if ($proc.ExitCode -ne 0) {
  Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
  throw "Could not decrypt the file: wrong password, or the file is damaged. (OpenSSL said: $($err.Trim()))"
}

# ---------- unpack ----------
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
& $tar -xzf $tmp -C $Destination
$code = $LASTEXITCODE
Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
if ($code -ne 0) { throw "Could not unpack the archive (tar exit code $code)." }

$current = Join-Path $Destination "_ProjectVault\current"
if (-not (Test-Path -LiteralPath $current)) { throw "Unpacked, but $current is missing. Is this a Project Vault backup?" }

Write-Host ""
Write-Host "Unpacked into $Destination" -ForegroundColor Green
Write-Host "Every file is in $current, at the same path it had in your projects folder."
Write-Host "Older versions are in $(Join-Path $Destination '_ProjectVault\history')."

# ---------- put files back ----------
if ($ProjectsFolder) {
  New-Item -ItemType Directory -Force -Path $ProjectsFolder | Out-Null
  $ProjectsFolder = (Resolve-Path -LiteralPath $ProjectsFolder).Path
  $copied = 0; $kept = 0; $failed = 0
  Get-ChildItem -LiteralPath $current -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($current.Length).TrimStart('\', '/')
    $target = Join-Path $ProjectsFolder $rel
    if ((Test-Path -LiteralPath $target) -and -not $Overwrite) {
      $kept++
      Write-Host "  already there: $rel"
    } else {
      try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        $copied++
        Write-Host "  restored:      $rel"
      } catch {
        $failed++
        Write-Warning "could not restore ${rel}: $($_.Exception.Message)"
      }
    }
  }
  Write-Host ""
  Write-Host "$copied restored into $ProjectsFolder, $kept already there (add -Overwrite to replace them), $failed failed." -ForegroundColor Green
}
