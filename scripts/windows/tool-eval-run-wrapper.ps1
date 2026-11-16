# WINDOWS-ARM64-PORT - detached Tool Eval run wrapper.
#
# Started by buildRunProgramWindows() via Start-Process -File. All run-specific
# values arrive through SPARKDASH_TE_* environment variables (inherited from the
# parent), so this file stays static: embedding it in the parent's
# -EncodedCommand would multiply the command line by ~7x and overflow the
# 32767-character Windows CreateProcess limit on realistic argument lists.
#
# Contract (mirrors the upstream bash program):
#   stdout.log   - display line + native stdout
#   events.jsonl - native stderr (JSONL progress events)
#   exit         - the CLI's real exit code
#   pid          - this wrapper's pid while running, removed on exit
#
# Windows PowerShell 5.1 ONLY: its 2>&1 wraps native stderr in ErrorRecord,
# which is how the two streams are separated here.

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = [Console]::OutputEncoding

function DecodeB64([string]$s) {
  [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}

$utf8 = New-Object System.Text.UTF8Encoding $false
$RD = $env:SPARKDASH_TE_RUN_DIR
$WD = $env:SPARKDASH_TE_WORK_DIR
$VENV = $env:SPARKDASH_TE_VENV
$L = Join-Path $RD "stdout.log"
$E = Join-Path $RD "events.jsonl"
$X = Join-Path $RD "exit"
$P = Join-Path $RD "pid"

$SCRIPTS = Join-Path $VENV "Scripts"
$bin = if (Test-Path (Join-Path $SCRIPTS "tool-eval-bench.exe")) {
  Join-Path $SCRIPTS "tool-eval-bench.exe"
} else {
  (Get-Command tool-eval-bench -ErrorAction SilentlyContinue).Source
}

# @(...) is required: a single argument would unwrap to a scalar string, and
# splatting a string makes PowerShell pass only its first character.
$argv = @((DecodeB64 $env:SPARKDASH_TE_ARGV_B64).Split("`0") | Where-Object { $_.Length -gt 0 })
$displayText = "[sparkdash] " + (DecodeB64 $env:SPARKDASH_TE_DISPLAY_B64)

[IO.File]::WriteAllText($L, $displayText + "`n", $utf8)
[IO.File]::WriteAllText($E, "", $utf8)
if (Test-Path $X) { Remove-Item $X -Force }
[IO.File]::WriteAllText($P, [string]$PID, $utf8)

Push-Location $WD
try {
  & $bin @argv 2>&1 | ForEach-Object {
    $t = [string]$_.ToString()
    if ($_ -is [System.Management.Automation.ErrorRecord]) {
      [IO.File]::AppendAllText($E, $t + "`n", $utf8)
    } else {
      [IO.File]::AppendAllText($L, $t + "`n", $utf8)
    }
  }
  $code = $LASTEXITCODE
  if ($null -eq $code) { $code = 0 }
} catch {
  $code = 1
  [IO.File]::AppendAllText($E, ("[sparkdash] " + [string]$_.Exception.Message) + "`n", $utf8)
} finally {
  Pop-Location
}

[IO.File]::WriteAllText($X, [string]$code, $utf8)
Remove-Item $P -Force -ErrorAction SilentlyContinue
