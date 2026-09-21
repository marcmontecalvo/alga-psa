<#
.SYNOPSIS
Operate the local, non-production Alga PSA EE evaluation stack.
.EXAMPLE
.\local-stack.ps1
.\local-stack.ps1 -Stop
.\local-stack.ps1 -Fresh
.\local-stack.ps1 -Pull -SyncFork
.\local-stack.ps1 -Rebuild
#>
[CmdletBinding()]
param(
    [switch]$Fresh,
    [switch]$ConfirmFresh,
    [switch]$Pull,
    [switch]$SyncFork,
    [switch]$Rebuild,
    [switch]$Workers,
    [switch]$Stop,
    [switch]$Status,
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

function New-LocalSecret {
    $secretBytes = New-Object byte[] 32
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($secretBytes) } finally { $random.Dispose() }
    return [Convert]::ToBase64String($secretBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

Push-Location $repo
try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker CLI is not available.' }
    if (-not (Test-Path -LiteralPath $envFile)) { throw "Missing $envFile" }
    foreach ($secretName in @('HOCUSPOCUS_JWT_SECRET', 'COLLAB_PERSIST_API_KEY')) {
        if ([string]::IsNullOrWhiteSpace((Get-EnvValue $secretName ''))) {
            Set-EnvValue $secretName (New-LocalSecret)
            Write-Host "Generated local $secretName in .env."
        }
    }
    Invoke-Compose -Arguments @('config', '--quiet')

    if ($ValidateOnly) {
        Write-Host 'Compose configuration is valid. No containers or volumes were changed.'
        return
    }
    if ($Stop) {
        Invoke-Compose -Arguments @('down', '--remove-orphans')
        Write-Host 'Alga stopped. Database, uploaded files, and images were retained.'
        return
    }
    if ($Status) {
        Invoke-Compose -Arguments @('ps', '-a')
        return
    }
    if ($SyncFork -and -not $Pull) { throw '-SyncFork requires -Pull.' }

    $sourceChanged = $false
    if ($Pull) {
        $dirty = & git status --porcelain
        if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Commit or stash local changes before pulling upstream.' }
        $beforePull = (& git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not resolve current Git commit.' }
        & git fetch origin release/1.6.0
        if ($LASTEXITCODE -ne 0) { throw 'Fetching upstream release/1.6.0 failed.' }
        & git merge --no-edit origin/release/1.6.0
        if ($LASTEXITCODE -ne 0) { throw 'Upstream merge needs review. Resolve conflicts before retrying; containers were not changed.' }
        $afterPull = (& git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not resolve merged Git commit.' }
        $sourceChanged = $beforePull -ne $afterPull
    }

    $currentVolume = Get-EnvValue 'ALGA_PG_VOLUME' 'alga-psa-postgres-data'
    $bootstrap = $false
    if ($Fresh) {
        Write-Warning "Fresh mode stops the stack and switches away from $currentVolume. The old database is retained."
        if (-not $ConfirmFresh) {
            $answer = Read-Host 'Type FRESH to continue'
            if ($answer -cne 'FRESH') { throw 'Fresh run cancelled.' }
        }
        Invoke-Compose -Arguments @('down', '--remove-orphans')
        $newVolume = 'alga-psa-postgres-data-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        Invoke-Docker -Arguments @('volume', 'create', $newVolume)
        Set-EnvValue 'ALGA_PG_VOLUME' $newVolume
        $bootstrap = $true
        Set-EnvValue 'LOCAL_BOOTSTRAP_PENDING' 'true'
        Write-Host "Fresh database volume: $newVolume (previous volume retained: $currentVolume)"
    } else {
        $matchingVolumes = @(& docker volume ls --quiet --filter "name=^$([regex]::Escape($currentVolume))$")
        if ($LASTEXITCODE -ne 0) { throw 'Could not query Docker volumes.' }
        if ($currentVolume -notin $matchingVolumes) {
            Invoke-Docker -Arguments @('volume', 'create', $currentVolume)
            $bootstrap = $true
            Set-EnvValue 'LOCAL_BOOTSTRAP_PENDING' 'true'
        }
    }
    if ((Get-EnvValue 'LOCAL_BOOTSTRAP_PENDING' 'false') -eq 'true') { $bootstrap = $true }

    Invoke-Compose -Arguments @('config', '--quiet')
    $image = Get-EnvValue 'ALGA_EE_IMAGE' 'alga-psa-ee-local:release-1.6.0'
    $matchingImages = @(& docker image ls --quiet $image)
    if ($LASTEXITCODE -ne 0) { throw 'Could not query Docker images.' }
    if ($sourceChanged -or $Rebuild -or -not $matchingImages) {
        Write-Host 'Building the EE production image from this checkout. The first build may take a while.'
        Invoke-Compose -Arguments @('build', 'server')
    }
    Invoke-Docker -Arguments @('run', '--rm', '--entrypoint', 'sh', $image, '-c', 'test -f /app/ee/server/src/lib/testing/tenant-creation.ts && test -f /app/packages/db/dist/lib/tenantDb.js && test -f /app/server/scripts/create-tenant.ts')
    $redisImage = @(& docker image ls --quiet alga-psa-redis)
    $poolerImage = @(& docker image ls --quiet alga-psa-pgbouncer)
    $hocuspocusImage = @(& docker image ls --quiet alga-psa-hocuspocus)
    if ($LASTEXITCODE -ne 0) { throw 'Could not query supporting Docker images.' }
    if ($sourceChanged -or $Rebuild -or -not $redisImage -or -not $poolerImage -or -not $hocuspocusImage) {
        Invoke-Compose -Arguments @('build', 'redis', 'pgbouncer', 'hocuspocus')
    }
    Invoke-Compose -Arguments @('up', '-d', '--no-build', 'postgres', 'redis', 'pgbouncer', 'mailpit')
    Invoke-Compose -Arguments @('up', '-d', '--no-build', '--no-deps', '--force-recreate', 'setup')
    $setupId = (& docker @compose ps -q setup).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $setupId) { throw 'Setup container was not found.' }
    $setupExit = (& docker wait $setupId).Trim()
    if ($LASTEXITCODE -ne 0 -or $setupExit -ne '0') {
        throw "Setup failed (exit $setupExit). Inspect: docker compose -f compose.yaml logs setup"
    }

    Invoke-Compose -Arguments @('up', '-d', '--no-build', '--no-deps', '--wait', '--wait-timeout', '60', 'hocuspocus')
    Invoke-Compose -Arguments @('up', '-d', '--no-build', '--no-deps', 'temporal-dev')
    Invoke-Compose -Arguments @('up', '-d', '--no-build', '--no-deps', 'server')

    if ($bootstrap) {
        $adminEmail = Get-EnvValue 'LOCAL_ADMIN_EMAIL' 'admin@local.test'
        $tenantName = Get-EnvValue 'LOCAL_TENANT_NAME' 'Local Test'
        $serverId = (& docker @compose ps -q server).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $serverId) { throw 'Could not locate the server container.' }
        $previousErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $tenantOutput = & docker exec $serverId sh /usr/local/bin/local-bootstrap.sh $tenantName $adminEmail 2>&1
            $tenantExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }
        if ($tenantExit -ne 0) {
            $tenantOutput | ForEach-Object { Write-Host $_ }
            throw 'Fresh database initialized, but the supported create-tenant CLI failed.'
        }
        $tenantOutput | ForEach-Object { Write-Host $_ }
        if (-not ($tenantOutput | Where-Object { $_ -match '^Temporary Password:\s*\S+' })) {
            throw 'Tenant was created, but its temporary password was not returned.'
        }
        Set-EnvValue 'LOCAL_BOOTSTRAP_PENDING' 'false'
        Write-Host 'Save the temporary password now and change it after login. It is not stored in .env.'
    }

    $appReady = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try { $httpCode = & curl.exe -sS -o NUL -w '%{http_code}' --max-time 5 http://localhost:3000/api/healthz 2>$null }
        catch { $httpCode = '' }
        if ($httpCode -eq '200') { $appReady = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $appReady) { throw 'Alga healthz did not respond at http://localhost:3000/api/healthz.' }

    if ($Workers) {
        Invoke-Compose -Arguments @('--profile', 'workers', 'up', '-d', '--build', 'workflow-worker', 'email-service', 'temporal-worker')
    }
    if ($SyncFork) {
        $branch = (& git branch --show-current).Trim()
        if ($LASTEXITCODE -ne 0 -or $branch -ne 'local-release') { throw 'Refusing to push a branch other than local-release.' }
        & git push fork HEAD:local-release
        if ($LASTEXITCODE -ne 0) { throw 'Alga started, but pushing the updated branch to the fork failed.' }
    }
    Invoke-Compose -Arguments @('ps')
    Write-Host 'Alga: http://localhost:3000  Mailpit: http://localhost:8025'
} finally {
    Pop-Location
}
