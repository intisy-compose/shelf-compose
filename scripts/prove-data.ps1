# Dot-source only. Needs docker-compose.ps1's Invoke-Backup and data-on-disk.ps1.

$ProveProject = "shelf-compose"
$ProveBackupContainer = "shelf-db-backup"
$ProveDatabaseContainer = "shelf-db"
$ProveKeyFile = Join-Path $PSScriptRoot "..\data\secrets\pgsodium_root.key"

<#
.SYNOPSIS
Table-by-table differences between two row-count maps, as printable lines; empty when they match.
#>
function Compare-TableCounts([System.Collections.IDictionary]$Before, [System.Collections.IDictionary]$After) {
    $differences = @()
    foreach ($name in (@($Before.Keys) + @($After.Keys) | Sort-Object -Unique)) {
        $beforeCount = if ($Before.Contains($name)) { $Before[$name] } else { "missing" }
        $afterCount = if ($After.Contains($name)) { $After[$name] } else { "missing" }
        if ("$beforeCount" -ne "$afterCount") { $differences += "$name before=$beforeCount after=$afterCount" }
    }
    return $differences
}

function Get-ShelfTableCounts {
    return Get-TableRowCounts $ProveBackupContainer "db" "supabase_admin" "postgres"
}

function Test-ContainerIsRunning([string]$Name) {
    return [bool](docker ps -q --filter "name=^$Name$")
}

<#
.SYNOPSIS
Runs a docker-compose.ps1 verb; only "down" has its exit code trusted.
.NOTES
After "up" the exit code belongs to whichever native call ran last inside it, not to "up" itself, so
success after "up" is judged by the table counts instead.
#>
function Invoke-Stack([string]$Verb) {
    & (Join-Path $PSScriptRoot "..\docker-compose.ps1") $Verb
    if ($Verb -eq "down" -and $LASTEXITCODE -ne 0) { throw "docker-compose.ps1 down failed with exit code $LASTEXITCODE" }
}

function Write-RecoveryHint([string]$DumpName) {
    Write-Err "The volumes were deleted. Recover with: .\docker-compose.ps1 up"
    Write-Err "If that keeps failing: .\docker-compose.ps1 up -Fresh   then   .\docker-compose.ps1 restore $DumpName"
}

<#
.SYNOPSIS
Names of this stack's own volumes, matched by compose project label and re-checked by name prefix.
.NOTES
Never returns a volume of another project, whatever the label filter says.
#>
function Get-StackVolumes {
    $names = @(docker volume ls -q --filter "label=com.docker.compose.project=$ProveProject")
    if ($LASTEXITCODE -ne 0) { throw "could not list the volumes of $ProveProject" }
    return @($names | Where-Object { $_ -and $_.StartsWith("${ProveProject}_") })
}

function Remove-StackVolumes {
    $volumes = Get-StackVolumes
    if (-not $volumes) { throw "no volume labelled com.docker.compose.project=$ProveProject was found" }
    $volumes | ForEach-Object { Write-Host "  removing $_" -ForegroundColor Gray }
    docker volume rm @volumes
    if ($LASTEXITCODE -ne 0) { throw "could not remove the volumes of $ProveProject" }
}

<#
.SYNOPSIS
Prove that deleting every volume of the stack loses nothing: dump, count, delete, start, count.
.NOTES
DESTRUCTIVE: it deletes the stack's volumes. Run it only with the owner's go-ahead. Refuses to start
without data\secrets\pgsodium_root.key, because the restored database cannot be decrypted without it.
A fresh dump is taken right before the "before" count, so writes after an older dump cannot look like
a failed restore. The stack must be running, because the counts come from its database.
#>
function Invoke-ProveData {
    if (-not (Test-Path -LiteralPath $ProveKeyFile)) { throw "data\secrets\pgsodium_root.key is missing; the restored database could not be decrypted" }
    foreach ($container in @($ProveBackupContainer, $ProveDatabaseContainer)) {
        if (-not (Test-ContainerIsRunning $container)) { throw "$container is not running; start the stack first" }
    }

    Write-Step "Writing a fresh dump ..."
    Invoke-Backup
    $newest = Get-NewestDump (Join-Path $PSScriptRoot "..\data\backups") "shelf-*.dump"
    if (-not $newest) { throw "no complete dump exists in data\backups" }
    if (-not (Test-DumpIsRestorable $newest)) { throw "$($newest.Name) cannot be listed by pg_restore or holds no table data; nothing was deleted" }

    Write-Step "Counting rows before ..."
    $before = Get-ShelfTableCounts
    Write-Host "  $($before.Count) tables, dump $($newest.Name)" -ForegroundColor Gray

    Write-Step "Stopping the stack and deleting its volumes ..."
    try {
        Invoke-Stack "down"
        Remove-StackVolumes

        Write-Step "Starting the stack and waiting for the self-restore ..."
        Invoke-Stack "up"

        Write-Step "Counting rows after ..."
        $after = Get-ShelfTableCounts
    }
    catch { Write-RecoveryHint $newest.Name; throw }
    $differences = Compare-TableCounts $before $after
    if ($differences) {
        $differences | ForEach-Object { Write-Host "  DIFFERS $_" -ForegroundColor Red }
        Write-RecoveryHint $newest.Name
        exit 1
    }
    Write-Host "  all $($after.Count) tables match" -ForegroundColor Green
    Write-OK "every table came back"
}
