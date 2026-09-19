<#
.SYNOPSIS
Build and run this local Alga PSA checkout without editing upstream files.
.EXAMPLE
.\local-stack.ps1
Rebuild and recreate the stack while keeping the selected PostgreSQL volume.
.EXAMPLE
.\local-stack.ps1 -Fresh
Switch to a new empty PostgreSQL volume and create a new tenant/admin login.
#>
[CmdletBinding()]
param(
    [switch]$Fresh,
    [switch]$ConfirmFresh,
    [switch]$Pull,
    [switch]$SkipBuild,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$envFile = Join-Path $repo '.env'
$compose = @('compose', '--env-file', 'server/.env', '--env-file', '.env', '-f', 'compose.yaml')

function Invoke-Docker([string[]]$Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed (exit $LASTEXITCODE): docker $($Arguments -join ' ')"
    }
}

function Invoke-Compose([string[]]$Arguments) {
    Invoke-Docker -Arguments ($compose + $Arguments)
}

function Get-EnvValue([string]$Name, [string]$Default) {
    if (-not (Test-Path -LiteralPath $envFile)) { return $Default }
    $content = [System.IO.File]::ReadAllText($envFile)
    $match = [regex]::Match($content, '(?m)^' + [regex]::Escape($Name) + '=([^\r\n]*)')
    if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) { return $Default }
    return $match.Groups[1].Value.Trim('"').Trim("'")
}

function Set-EnvValue([string]$Name, [string]$Value) {
    $content = if (Test-Path -LiteralPath $envFile) { [System.IO.File]::ReadAllText($envFile) } else { '' }
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=[^\r\n]*'
    if ([regex]::IsMatch($content, $pattern)) {
        $content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) "$Name=$Value" })
    } else {
        if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { $content += "`r`n" }
        $content += "$Name=$Value`r`n"
    }
    [System.IO.File]::WriteAllText($envFile, $content, [System.Text.UTF8Encoding]::new($false))
}

Push-Location $repo
try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker CLI is not available.' }
    if (-not (Test-Path -LiteralPath $envFile)) { throw "Missing $envFile" }
    Invoke-Compose -Arguments @('config', '--quiet')

    $currentVolume = Get-EnvValue 'ALGA_PG_VOLUME' 'alga-psa-postgres-data'
    Write-Host "Source: $repo"
    Write-Host "PostgreSQL volume: $currentVolume"
    if ($ValidateOnly) {
        Write-Host 'Compose configuration is valid. No containers or volumes were changed.'
        return
    }

    if ($Pull) {
        & git pull --ff-only
        if ($LASTEXITCODE -ne 0) { throw 'Git fast-forward pull failed; no containers were changed.' }
    }

    if ($Fresh) {
        Write-Warning "Fresh mode will stop the Alga stack and switch away from $currentVolume. The old volume will be kept."
        if (-not $ConfirmFresh) {
            $answer = Read-Host 'Type FRESH to continue'
            if ($answer -cne 'FRESH') { throw 'Fresh run cancelled.' }
        }
    }

    # Down never uses -v. Named PostgreSQL data and other volumes are retained.
    Invoke-Compose -Arguments @('down', '--remove-orphans')

    if ($Fresh) {
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $newVolume = 'alga-psa-postgres-data-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $suffix
        Invoke-Docker -Arguments @('volume', 'create', $newVolume)
        Set-EnvValue 'ALGA_PG_VOLUME' $newVolume
        Write-Host "Fresh PostgreSQL volume: $newVolume"
        Write-Host "Previous volume retained: $currentVolume"
    } elseif (-not (& docker volume inspect $currentVolume 2>$null)) {
        Invoke-Docker -Arguments @('volume', 'create', $currentVolume)
    }

    Invoke-Compose -Arguments @('config', '--quiet')
    if (-not $SkipBuild) {
        Invoke-Compose -Arguments @('build', 'server', 'setup', 'hocuspocus', 'redis', 'pgbouncer')
    }
    # Start in stages. The upstream all-at-once up can reserve the server name
    # while PostgreSQL/setup is still starting and leave a half-created container.
    Invoke-Compose -Arguments @('up', '-d', '--no-build', 'postgres', 'redis', 'pgbouncer', 'mailpit')
    Invoke-Compose -Arguments @('up', '-d', '--no-build', '--no-deps', '--force-recreate', 'setup')

    $setupId = (& docker @compose ps -q setup).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $setupId) { throw 'Setup container was not found.' }
    $setupExit = (& docker wait $setupId).Trim()
    if ($LASTEXITCODE -ne 0 -or $setupExit -ne '0') {
        throw "Setup failed (container exit $setupExit). Inspect: docker compose -f compose.yaml logs setup"
    }

    # Temporal exits if it reaches PostgreSQL during crash recovery.
    Invoke-Compose -Arguments @('up', '-d', '--no-build', '--no-deps', 'temporal-dev')
    Invoke-Compose -Arguments @('up', '-d', '--no-build', '--no-deps', 'hocuspocus')
    Invoke-Compose -Arguments @('up', '-d', '--no-build', '--no-deps', 'server')

    if ($Fresh) {
        # The CLI only needs the migrated database, not a compiled HTTP route.
        $adminEmail = Get-EnvValue 'LOCAL_ADMIN_EMAIL' 'admin@local.test'
        $tenantName = Get-EnvValue 'LOCAL_TENANT_NAME' 'Local Test'
        $serverId = (& docker @compose ps -q server).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $serverId) { throw 'Could not locate the running Alga server container.' }
        $tenantOutput = & docker exec $serverId npm --prefix /app/server run create-tenant -- --tenant $tenantName --email $adminEmail 2>&1
        if ($LASTEXITCODE -ne 0) {
            $tenantOutput | ForEach-Object { Write-Host $_ }
            throw 'The fresh database started, but creating its initial admin failed.'
        }
        $passwordLine = $tenantOutput | Where-Object { $_ -match '^Temporary Password:\s*(.+)$' } | Select-Object -Last 1
        if (-not $passwordLine) { throw 'Tenant creation succeeded, but no temporary password was returned.' }
        $adminPassword = ([regex]::Match($passwordLine, '^Temporary Password:\s*(.+)$')).Groups[1].Value.Trim()
        Set-EnvValue 'LOCAL_ADMIN_EMAIL' $adminEmail
        Set-EnvValue 'LOCAL_ADMIN_PASSWORD' $adminPassword
        Write-Host "Initial login: $adminEmail"
        Write-Host "Initial password: $adminPassword"
        Write-Host 'These credentials were also saved in the ignored .env file.'
    }

    $appReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $httpCode = & curl.exe -sS -o NUL -w '%{http_code}' --max-time 5 http://localhost:3000/api/healthz 2>$null
        } catch {
            $httpCode = '' # A cold Next.js compile can drop early HTTP connections.
        }
        if ($httpCode -eq '200') { $appReady = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $appReady) { throw 'Alga healthz did not respond on http://localhost:3000 after startup.' }

    foreach ($service in @('postgres', 'pgbouncer', 'redis', 'temporal-dev', 'hocuspocus', 'mailpit', 'server')) {
        $containerId = (& docker @compose ps -q $service).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $containerId) { throw "Required service is not running: $service" }
        $running = (& docker inspect --format '{{.State.Running}}' $containerId).Trim()
        if ($LASTEXITCODE -ne 0 -or $running -ne 'true') { throw "Required service is not running: $service" }
    }

    if (-not $Fresh) {
        Write-Host 'Stack rebuilt with the existing PostgreSQL volume and login unchanged.'
    }

    Write-Host 'Alga: http://localhost:3000  Mailpit: http://localhost:8025  PostHog: http://localhost:8010'
} finally {
    Pop-Location
}
