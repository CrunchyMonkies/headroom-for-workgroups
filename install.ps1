<#
.SYNOPSIS
  headroom-for-workgroups client bootstrap for Windows.

.DESCRIPTION
  Installs the Headroom and Ix CLIs, stops the local Ix Docker backend (which
  would otherwise give you a second, divergent graph), and writes the endpoint
  and token configuration. Re-running it is safe.

  The PowerShell counterpart of install.sh. See docs/03-install-cli.md and
  docs/04-connect-cli-to-server.md for the same steps done by hand.

.PARAMETER HeadroomUrl
  Base URL of the Headroom proxy, e.g. https://headroom.example.com
  Defaults to $env:HEADROOM_URL.

.PARAMETER IxUrl
  Base URL of the Ix memory-layer, e.g. https://ix.example.com
  Defaults to $env:IX_URL.

.PARAMETER Token
  Headroom proxy token. Lands in your PowerShell history - prefer -TokenFile.

.PARAMETER TokenFile
  Read the token from a file instead.

.PARAMETER TokenCommand
  Do not store the token at all: the generated config runs this PowerShell
  expression to fetch it, e.g. '(Get-Secret headroom-token -AsPlainText)'.

.PARAMETER WriteProfile
  Load the config from $PROFILE and persist the base URLs at user scope so
  GUI-launched editors see them. Off by default; the line is printed instead.

.EXAMPLE
  .\install.ps1 -HeadroomUrl https://headroom.example.com `
                -IxUrl https://ix.example.com -TokenFile .\token

.EXAMPLE
  # Cluster-internal servers reached over kubectl port-forward. Loopback callers
  # are exempt from the Headroom token, so none is needed.
  .\install.ps1 -HeadroomUrl http://127.0.0.1:8787 -IxUrl http://127.0.0.1:8090
#>

# Write-Host is deliberate throughout: this is an interactive installer whose
# output is the user interface, not data for a pipeline.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Installer progress output is for a human at a terminal, not a pipeline.')]
# PSSA does not track parameter reads across function boundaries; every
# parameter below is read by the functions in this file.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Parameters are consumed inside the functions defined below.')]
[CmdletBinding()]
param(
    [string] $HeadroomUrl  = $env:HEADROOM_URL,
    [string] $IxUrl        = $env:IX_URL,
    [string] $Token        = $env:HEADROOM_PROXY_TOKEN,
    [string] $TokenFile    = '',
    [string] $TokenCommand = '',
    [switch] $SkipHeadroom,
    [switch] $SkipIx,
    [switch] $WriteProfile,
    [switch] $NoVerify,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Warnings = 0

# $IsWindows only exists on PowerShell 6+; on 5.1 the answer is always yes.
# `if` short-circuits, so 5.1 never evaluates the undefined variable.
$script:OnWindows = if ($PSVersionTable.PSVersion.Major -lt 6) { $true } else { $IsWindows }

# --- output ------------------------------------------------------------------

function Write-Section { param([string] $Text) Write-Host "`n== $Text" -ForegroundColor White }
function Write-Ok      { param([string] $Text) Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Info    { param([string] $Text) Write-Host "         $Text" }
function Write-Dry     { param([string] $Text) Write-Host "  [dry]  $Text" -ForegroundColor Yellow }
function Write-Fail    { param([string] $Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red }

function Write-Warn {
    param([string] $Text)
    Write-Host "  [warn] $Text" -ForegroundColor Yellow
    $script:Warnings++
}

function Test-Command {
    param([string] $Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# Invoke-Step is the single place -DryRun is honoured.
function Invoke-Step {
    param(
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [scriptblock] $Action
    )
    if ($DryRun) { Write-Dry $Description; return }
    & $Action
}

# --- argument checking -------------------------------------------------------

function Confirm-CommandLine {
    $given = @($Token, $TokenFile, $TokenCommand | Where-Object { $_ })
    if ($given.Count -gt 1) { throw 'Give the token exactly one way: -Token, -TokenFile or -TokenCommand.' }

    if ($TokenFile) {
        if (-not (Test-Path -LiteralPath $TokenFile)) { throw "Cannot read token file: $TokenFile" }
        $raw = Get-Content -LiteralPath $TokenFile -Raw
        if (-not $raw) { throw "Token file is empty: $TokenFile" }
        $script:Token = $raw.Trim()
    }
    elseif ($Token) {
        Write-Warn '-Token puts the token in your PowerShell history; -TokenFile or -TokenCommand avoid that'
    }

    if ($SkipHeadroom -and $SkipIx) { throw 'Skipping both components leaves nothing to do.' }
    if (-not $SkipHeadroom -and -not $HeadroomUrl) { throw '-HeadroomUrl is required (or -SkipHeadroom).' }
    if (-not $SkipIx -and -not $IxUrl) { throw '-IxUrl is required (or -SkipIx).' }

    $script:HeadroomUrl = $HeadroomUrl.TrimEnd('/')
    $script:IxUrl = $IxUrl.TrimEnd('/')
}

# --- preflight ---------------------------------------------------------------
#
# Everything is checked before anything is installed: failing halfway leaves a
# machine that is neither the old state nor the new one.

function Test-Prerequisite {
    Write-Section 'preflight'
    Write-Info "PowerShell $($PSVersionTable.PSVersion)"

    $missing = @()

    if (-not $SkipHeadroom) {
        if (Test-Command 'uv')         { Write-Ok 'uv (preferred installer for headroom)' }
        elseif (Test-Command 'pipx')   { Write-Ok 'pipx (headroom fallback)' }
        elseif (Test-Command 'python') { Write-Warn "no uv or pipx - falling back to 'pip install --user'" }
        else {
            $missing += 'uv, pipx, or python for the Headroom CLI (get uv: https://astral.sh/uv)'
        }
    }

    if (-not $SkipIx) {
        if (Test-Command 'node') {
            $raw = (& node -v) -replace '^v', ''
            $major = [int](($raw -split '\.')[0])
            if ($major -ge 22) { Write-Ok "node v$raw" }
            else { $missing += "node v$raw is too old - Ix needs 22+" }
        }
        else { $missing += 'node - Ix needs 22+' }

        if (Test-Command 'rg') { Write-Ok 'ripgrep' }
        else { $missing += 'ripgrep (rg) - Ix needs it to walk repositories' }
    }

    if ($missing.Count -gt 0) {
        foreach ($m in $missing) { Write-Fail $m }
        # A dry run changes nothing, so there is nothing to protect by aborting -
        # and it stays useful for inspecting what a real run would do.
        if ($DryRun) { Write-Warn 'prerequisites missing - a real run would stop here' }
        else { throw 'Install the missing prerequisites and re-run.' }
    }
}

# --- the Headroom CLI --------------------------------------------------------

function Install-HeadroomCli {
    Write-Section 'headroom CLI'

    if (Test-Command 'headroom') { Write-Info "already installed: $(& headroom --version 2>$null)" }

    # The [all] extra pulls the local compression models. It costs little and
    # keeps offline use working.
    if (Test-Command 'uv') {
        Invoke-Step 'uv tool install --python 3.13 --force "headroom-ai[all]"' {
            & uv tool install --python 3.13 --force 'headroom-ai[all]'
        }
    }
    elseif (Test-Command 'pipx') {
        Invoke-Step 'pipx install --force "headroom-ai[all]"' {
            & pipx install --force 'headroom-ai[all]'
        }
    }
    else {
        # --user, never an elevated prompt: a machine-wide site-packages owned by
        # this script is a worse problem than a PATH warning.
        Invoke-Step 'python -m pip install --user --upgrade "headroom-ai[all]"' {
            & python -m pip install --user --upgrade 'headroom-ai[all]'
        }
    }

    if (-not $DryRun) {
        if (Test-Command 'headroom') { Write-Ok 'headroom installed' }
        else { Write-Warn 'headroom installed but not on PATH - open a new terminal' }
    }
}

# --- the Ix CLI --------------------------------------------------------------

function Install-IxCli {
    Write-Section 'ix CLI'

    if (Test-Command 'ix') { Write-Info "already installed: $(& ix --version 2>$null)" }

    # Delegate to upstream rather than reimplementing their release layout - it
    # would rot the first time they change it. Their published one-liner is
    # `irm https://ix-infra.com/install.ps1 | iex`; this runs the same script in
    # a child process instead. In-process it calls `exit` on any failure, which
    # ends *this* script too and silently skips every configuration step below.
    #
    # Yes, this executes code fetched from the network - the same trust decision
    # as their one-liner, and as `curl | sh` in install.sh. -SkipIx opts out.
    Invoke-Step 'download https://ix-infra.com/install.ps1 and run it' {
        $installer = Invoke-RestMethod -Uri 'https://ix-infra.com/install.ps1'
        $dir = New-Item -ItemType Directory -Path (
            Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName()))
        try {
            # Lock the directory down before the script lands in it: nothing else
            # on a shared machine gets to swap it out between write and execute.
            Protect-Path $dir.FullName -PosixMode 700
            $file = Join-Path $dir.FullName 'ix-install.ps1'
            Set-Content -LiteralPath $file -Value $installer -Encoding utf8
            & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $file
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "upstream's ix installer exited $LASTEXITCODE - see its output above"
            }
        }
        finally {
            Remove-Item -Recurse -Force -LiteralPath $dir.FullName -ErrorAction SilentlyContinue
        }

        if (Test-Command 'ix') { Write-Ok 'ix installed' }
        else { Write-Warn 'ix is not on PATH - open a new terminal, then re-run this script' }
    }

    # The upstream installer also sets up a local Docker ArangoDB + memory-layer.
    # Against a shared backend that is actively harmful: two graphs, divergent
    # answers. This is the step hand-installers forget.
    Write-Section 'local Ix backend'
    if ($DryRun) {
        Write-Dry 'ix docker stop'
    }
    elseif (Test-Command 'ix') {
        & ix docker stop 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'local backend stopped - the shared one is the only graph' }
        else { Write-Ok 'no local backend was running' }
    }
    else {
        Write-Warn "ix is not on PATH yet; run 'ix docker stop' once it is"
    }
}

# --- configuration -----------------------------------------------------------

function Get-ConfigDir {
    Join-Path $HOME '.config/headroom-workgroup'
}

function Get-ConfigFile {
    Join-Path (Get-ConfigDir) 'env.ps1'
}

function Write-WorkgroupConfig {
    Write-Section 'configuration'

    if (-not $SkipIx) {
        # IX_ENDPOINT from env.ps1 wins over this at runtime, but writing the
        # config file too means `ix` works in a session that never loaded it.
        if ($DryRun) {
            Write-Dry "ix config set endpoint $IxUrl"
        }
        elseif (Test-Command 'ix') {
            & ix config set endpoint $IxUrl | Out-Null
            Write-Ok "ix endpoint -> $IxUrl  (~/.ix/config.yaml)"
        }
        else {
            Write-Warn "ix is not on PATH; run: ix config set endpoint $IxUrl"
        }
    }

    Write-EnvFile
}

function Get-TokenLine {
    if ($TokenCommand) { return "`$env:HEADROOM_PROXY_TOKEN = $TokenCommand" }
    if ($Token) {
        $escaped = $Token.Replace("'", "''")
        return "`$env:HEADROOM_PROXY_TOKEN = '$escaped'"
    }
    return "# `$env:HEADROOM_PROXY_TOKEN = (Get-Secret headroom-token -AsPlainText)"
}

# Restrict a path to the current user. Used for the config file, which may hold a
# bearer token, and for the scratch directory the ix installer is run from.
# Non-Windows PowerShell has no icacls; chmod is the equivalent.
function Protect-Path {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $PosixMode = '600'
    )
    if ($script:OnWindows) {
        & icacls $Path /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
    }
    else {
        & chmod $PosixMode $Path
    }
}

function Write-EnvFile {
    $file = Get-ConfigFile

    if ($DryRun) { Write-Dry "write $file (owner-only)"; return }

    New-Item -ItemType Directory -Force -Path (Get-ConfigDir) | Out-Null

    # Create the file empty and lock it down *before* the token goes in, so it
    # never exists - even for an instant - readable by anyone else.
    Set-Content -LiteralPath $file -Value '' -Encoding utf8
    Protect-Path $file

    $lines = @(
        '# Written by headroom-for-workgroups install.ps1. Safe to edit.'
        '# Load it from your profile:'
        "#   . '$file'"
        ''
    )

    if (-not $SkipHeadroom) {
        $lines += @(
            '# ---- Headroom (shared compression proxy) ----'
            "`$env:ANTHROPIC_BASE_URL = '$HeadroomUrl'"
            "`$env:OPENAI_BASE_URL = '$HeadroomUrl/v1'"
            (Get-TokenLine)
            "`$env:ANTHROPIC_CUSTOM_HEADERS = `"X-Headroom-Proxy-Token: `$(`$env:HEADROOM_PROXY_TOKEN)`""
            ''
            '# Your own provider key is NOT set here and does not change. The proxy'
            '# holds no provider credentials - it forwards whatever key your client'
            '# sends. Leave ANTHROPIC_API_KEY / OPENAI_API_KEY exactly as they were.'
            ''
        )
    }

    if (-not $SkipIx) {
        $lines += @(
            '# ---- Ix (shared codebase graph) ----'
            "`$env:IX_ENDPOINT = '$IxUrl'"
            ''
            '# Auto-map is off against a remote backend on purpose: otherwise every'
            '# client pushes a write on every file change. Run "ix map ." when you'
            '# want the graph refreshed. IX_AUTO_MAP_CLOUD=1 opts back in.'
        )
    }

    Set-Content -LiteralPath $file -Value $lines -Encoding utf8
    Write-Ok "wrote $file ($(if ($script:OnWindows) { 'owner-only ACL' } else { 'mode 600' }))"

    if ($Token -and -not $TokenCommand) {
        Write-Info 'the token is in that file in clear text; -TokenCommand keeps it in a secret manager instead'
    }
    elseif (-not $Token -and -not $TokenCommand -and -not $SkipHeadroom) {
        Write-Warn 'no token given - /v1/* will answer 401 unless you reach the proxy over loopback'
    }
}

# --- profile -----------------------------------------------------------------

function Write-ShellProfile {
    Write-Section 'profile'
    $file = Get-ConfigFile
    $marker = '# >>> headroom-for-workgroups >>>'

    # Default to printing. A bootstrap script rewriting someone's profile unasked
    # is worse than one extra copy-paste; upstream's ix installer does the same.
    if (-not $WriteProfile) {
        Write-Info 'add this to your $PROFILE (or re-run with -WriteProfile):'
        Write-Host ''
        Write-Host "    . '$file'"
        Write-Host ''
        return
    }

    if ($DryRun) {
        Write-Dry "append the load line to $PROFILE"
        Write-Dry 'persist ANTHROPIC_BASE_URL / OPENAI_BASE_URL / IX_ENDPOINT at user scope'
        return
    }

    # -Force on an existing file would truncate it, so only create what is absent.
    if (-not (Test-Path -LiteralPath $PROFILE)) {
        New-Item -ItemType File -Force -Path $PROFILE | Out-Null
    }

    if (Select-String -LiteralPath $PROFILE -SimpleMatch $marker -Quiet) {
        Write-Ok 'profile already loads it'
    }
    else {
        Add-Content -LiteralPath $PROFILE -Value @(
            ''
            $marker
            "if (Test-Path '$file') { . '$file' }"
            '# <<< headroom-for-workgroups <<<'
        )
        Write-Ok "appended to $PROFILE"
    }

    # Editors and agents launched from the GUI never read $PROFILE, so the base
    # URLs also go into the user environment. The token deliberately does not:
    # user-scope environment variables are readable by every process you run.
    if ($script:OnWindows) {
        if (-not $SkipHeadroom) {
            [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $HeadroomUrl, 'User')
            [Environment]::SetEnvironmentVariable('OPENAI_BASE_URL', "$HeadroomUrl/v1", 'User')
        }
        if (-not $SkipIx) {
            [Environment]::SetEnvironmentVariable('IX_ENDPOINT', $IxUrl, 'User')
        }
        Write-Ok 'base URLs persisted at user scope (the token was not - it stays in the config file)'
    }
}

# --- verification ------------------------------------------------------------

function Test-Deployment {
    if ($NoVerify -or $DryRun) { return }
    Write-Section 'verify'

    if (-not $SkipHeadroom) {
        try {
            # /readyz is auth-exempt by design, so this tests reachability without
            # depending on the token being right.
            Invoke-WebRequest -Uri "$HeadroomUrl/readyz" -TimeoutSec 10 -UseBasicParsing | Out-Null
            Write-Ok "$HeadroomUrl/readyz"
        }
        catch {
            Write-Warn "$HeadroomUrl/readyz unreachable - fine if the cluster is not up or the port-forward is not running"
        }
    }

    if (-not $SkipIx -and (Test-Command 'ix')) {
        & ix status 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "ix status against $IxUrl" }
        else { Write-Warn "'ix status' failed - check the endpoint and any auth layer in front of it" }
    }
}

# --- summary -----------------------------------------------------------------

function Write-Summary {
    Write-Section 'done'
    $file = Get-ConfigFile

    if (-not $SkipHeadroom) { Write-Info "headroom  -> $HeadroomUrl" }
    if (-not $SkipIx)       { Write-Info "ix        -> $IxUrl" }
    Write-Info "config    -> $file"

    if ($DryRun) {
        Write-Host "`n  dry run - nothing was installed or written`n" -ForegroundColor Yellow
        return
    }

    Write-Host "`n  Open a new terminal (or load the file), then:`n"
    Write-Host "    . '$file'"
    if (-not $SkipIx)       { Write-Host '    ix status' }
    if (-not $SkipHeadroom) { Write-Host '    irm "$env:ANTHROPIC_BASE_URL/readyz"' }
    Write-Host ''

    if ($script:Warnings -gt 0) {
        Write-Host "  $($script:Warnings) warning(s) above`n" -ForegroundColor Yellow
    }
}

# --- main --------------------------------------------------------------------

function Invoke-Main {
    Confirm-CommandLine
    Test-Prerequisite
    if (-not $SkipHeadroom) { Install-HeadroomCli }
    if (-not $SkipIx) { Install-IxCli }
    Write-WorkgroupConfig
    Write-ShellProfile
    Test-Deployment
    Write-Summary
}

Invoke-Main
