<#
Persistent local wrapper for LOOP.md.

Repeatedly invokes `claude -p` headlessly with a fixed scope prompt, so an
unattended overnight build survives Claude usage-limit resets without any
Claude session having to reschedule itself — the trigger here has no model
calls in it at all, so it can't die the way a session-local loop can. Backs
off on failure (covers a usage-limit block without needing to parse the exact
error) and resumes at normal cadence once a cycle succeeds again.

Per-cycle timeout is CI-aware: once a cycle passes -TimeoutMinutes it is only
killed if no GitHub Actions run is currently in flight for the repo. A cycle
that's genuinely waiting on `gh run watch` is left alone; a cycle that's
actually stuck (e.g. hung on a permission prompt nothing can answer) gets
killed at the next poll once CI goes idle.

Stops when the Claude session itself signals it's done or stuck, by creating
a `.loop-stop` file in the repo root (see LOOP.md's Stopping section).

Before every cycle the wrapper pushes any local commit a killed cycle made
but didn't get to push, then discards anything left uncommitted. This is
unconditional on purpose — no judgment call about whether a leftover diff is
worth finishing, just a clean slate every cycle. Units of work are small, so
redoing one is cheap.

Usage:
  .\loop.ps1 -Scope "Phase 0 — Core logic, provable without a Mac"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Scope,

    [int]$IntervalMinutes = 20,
    [int]$BackoffBaseMinutes = 30,
    [int]$MaxBackoffMinutes = 120,
    [int]$TimeoutMinutes = 60,
    [int]$PollSeconds = 120,
    [string]$RepoPath = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Error "claude CLI not found on PATH."
    exit 1
}

$logPath = Join-Path $RepoPath "loop.log"
$stopPath = Join-Path $RepoPath ".loop-stop"
$prompt = "Follow LOOP.md. Scope for this loop: $Scope."

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -Path $logPath -Value $line
}

$repoSlug = $null
if (Get-Command gh -ErrorAction SilentlyContinue) {
    Push-Location $RepoPath
    try {
        $repoSlug = (gh repo view --json nameWithOwner -q .nameWithOwner 2>$null)
    }
    catch {
        $repoSlug = $null
    }
    finally {
        Pop-Location
    }
}
if (-not $repoSlug) {
    Write-Log "WARNING: could not resolve the GitHub repo via gh — the CI-aware timeout will fall back to a flat ${TimeoutMinutes}m cap"
}

function Test-CiRunActive {
    if (-not $repoSlug) { return $false }
    try {
        $json = gh run list --repo $repoSlug --limit 1 --json status 2>$null
        if (-not $json) { return $false }
        $runs = $json | ConvertFrom-Json
        if ($runs.Count -eq 0) { return $false }
        return $runs[0].status -in @("in_progress", "queued", "requested", "waiting")
    }
    catch {
        return $false
    }
}

if (Test-Path $stopPath) {
    Remove-Item $stopPath -Force
    Write-Log "Removed stale .loop-stop left over from a previous run."
}

Write-Log "=== loop starting === scope: $Scope"
Write-Log "cadence ${IntervalMinutes}m / backoff ${BackoffBaseMinutes}m doubling to ${MaxBackoffMinutes}m cap / per-cycle timeout ${TimeoutMinutes}m (extended while CI is running)"

$consecutiveFailures = 0

while ($true) {
    Write-Log "cycle start"

    $pushOut = git -C $RepoPath push 2>&1
    Write-Log "pre-cycle push: $($pushOut -join ' ')"

    $dirty = git -C $RepoPath status --porcelain 2>$null
    if ($dirty) {
        Write-Log "working tree left dirty by a previous cycle — discarding uncommitted changes"
        git -C $RepoPath checkout -- . 2>$null | Out-Null
        git -C $RepoPath clean -fd 2>$null | Out-Null
    }

    $stdout = Join-Path $env:TEMP "loop-stdout-$(Get-Random).txt"
    $stderr = Join-Path $env:TEMP "loop-stderr-$(Get-Random).txt"

    $proc = Start-Process -FilePath "claude" `
        -ArgumentList @("-p", $prompt, "--output-format", "json", "--permission-mode", "dontAsk") `
        -WorkingDirectory $RepoPath `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $timedOut = $false

    while (-not $proc.HasExited) {
        if ((Get-Date) -ge $deadline) {
            if (Test-CiRunActive) {
                Write-Log "past ${TimeoutMinutes}m but a CI run is in flight — not killing yet"
            }
            else {
                $timedOut = $true
                break
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }

    $finished = $proc.HasExited

    if ($timedOut -and -not $finished) {
        Write-Log "cycle TIMED OUT (past ${TimeoutMinutes}m, no CI run in flight) — killing process"
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        $consecutiveFailures++
    }
    else {
        $exitCode = $proc.ExitCode
        $out = if (Test-Path $stdout) { Get-Content $stdout -Raw } else { "" }
        $err = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { "" }

        $isError = $exitCode -ne 0
        $resultSummary = $out
        try {
            $parsed = $out | ConvertFrom-Json
            if ($null -ne $parsed.is_error) { $isError = $isError -or $parsed.is_error }
            if ($parsed.result) { $resultSummary = $parsed.result }
        }
        catch {
            # Non-JSON output (e.g. a crash before the CLI could format a
            # result) — fall through and treat as an error below.
        }

        if ($isError) {
            Write-Log "cycle FAILED (exit $exitCode)"
            if ($err) {
                Write-Log "stderr: $($err.Substring(0, [Math]::Min(500, $err.Length)))"
            }
            $consecutiveFailures++
        }
        else {
            Write-Log "cycle OK"
            $consecutiveFailures = 0
        }

        if ($resultSummary) {
            $trimmed = $resultSummary.Substring(0, [Math]::Min(800, $resultSummary.Length))
            Write-Log "result: $trimmed"
        }
    }

    Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

    if (Test-Path $stopPath) {
        $reason = Get-Content $stopPath -Raw
        Write-Log "=== loop stopping === $reason"
        Remove-Item $stopPath -Force
        break
    }

    if ($consecutiveFailures -gt 0) {
        $waitMinutes = [Math]::Min($BackoffBaseMinutes * [Math]::Pow(2, $consecutiveFailures - 1), $MaxBackoffMinutes)
        Write-Log "backing off ${waitMinutes}m after $consecutiveFailures consecutive failure(s) — likely a usage limit or a transient error, either way a cold retry is safe"
        Start-Sleep -Seconds ($waitMinutes * 60)
    }
    else {
        Start-Sleep -Seconds ($IntervalMinutes * 60)
    }
}

Write-Log "=== loop exited cleanly ==="
