# Shared helpers for keeping a stack's data under its data/ folder and restoring an emptied database volume.
# Dot-source only: loading this file defines functions and does nothing else.
# Each stack vendors a byte copy as scripts/data-on-disk.ps1.

<#
.SYNOPSIS
True only when `docker volume inspect` failed because the volume does not exist.
.NOTES
A daemon outage, a permission error, a timeout or a missing docker binary (null exit code) are not
"missing", so they never lead to a restore over data.
#>
function Test-IsMissingVolumeAnswer([object]$ExitCode, [string]$Output) {
    return ($ExitCode -is [int]) -and ($ExitCode -ne 0) -and ($Output -match "no such volume")
}

<#
.SYNOPSIS
True when the named Docker volume does not exist or holds no Postgres cluster.
.NOTES
PG_VERSION marks a cluster. It is searched to depth 4 because pg0 keeps its cluster at
instances/<name>/data/. When Docker cannot answer, the result is false, so an unreadable
volume is never mistaken for an empty one and restored over.
#>
function Test-DatabaseVolumeIsEmpty([string]$Volume) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $inspectOutput = docker volume inspect $Volume 2>&1 | Out-String
        $inspectExitCode = $LASTEXITCODE
        if (Test-IsMissingVolumeAnswer $inspectExitCode $inspectOutput) { return $true }
        if ($inspectExitCode -ne 0) { return $false }
        $found = docker run --rm -v "${Volume}:/v:ro" alpine:3.21 find /v -maxdepth 4 -name PG_VERSION 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        return -not $found
    }
    finally { $ErrorActionPreference = $previousPreference }
}

<#
.SYNOPSIS
Every complete dump in a folder, newest first.
.NOTES
Dumps are named with a sortable timestamp, so name order is age order. A zero-byte file or a
.tmp is an interrupted dump and is never returned.
#>
function Get-CompleteDumps([string]$Folder, [string]$Pattern) {
    if (-not (Test-Path -LiteralPath $Folder)) { return @() }
    return @(Get-ChildItem -LiteralPath $Folder -Filter $Pattern -File |
        Where-Object { $_.Length -gt 0 -and $_.Extension -ne ".tmp" } |
        Sort-Object Name -Descending)
}

<#
.SYNOPSIS
The newest complete dump in a folder, or $null.
#>
function Get-NewestDump([string]$Folder, [string]$Pattern) {
    return Get-CompleteDumps $Folder $Pattern | Select-Object -First 1
}

<#
.SYNOPSIS
Row count of every base table outside pg_catalog and information_schema, keyed by schema.table.
.NOTES
One query counts all tables through query_to_xml, so there is no round trip per table.
#>
function Get-TableRowCounts([string]$Container, [string]$DatabaseHost, [string]$User, [string]$Database, [string]$Psql = "psql", [string]$Password = "") {
    $query = "select table_schema || '.' || table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema') order by 1"
    $environmentArguments = @()
    if ($Password) { $environmentArguments = @("-e", "PGPASSWORD=$Password") }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = docker exec @environmentArguments $Container $Psql -h $DatabaseHost -U $User -d $Database -At -F "|" -c $query
        if ($LASTEXITCODE -ne 0) { throw "psql in $Container failed with exit code $LASTEXITCODE" }
    }
    finally { $ErrorActionPreference = $previousPreference }
    $counts = [ordered]@{}
    foreach ($line in $lines) {
        if (-not $line) { continue }
        $name, $count = $line -split "\|", 2
        $counts[$name] = [long]$count
    }
    return $counts
}

<#
.SYNOPSIS
What `up` does with the database volume: Keep it, Restore Dump into it, start it Fresh, or Refuse.
.NOTES
Refuse answers an empty volume next to complete dumps that GetRejection all rejects: an empty
database started there would be dumped hourly and rotate those dumps out within BACKUP_KEEP hours.
GetRejection returns why a dump cannot be restored, or nothing when it can. AllowFresh starts an
empty database instead of restoring, but never touches a volume that holds one.
#>
function Get-RestoreDecision([string]$Volume, [string]$Folder, [string]$Pattern, [scriptblock]$GetRejection = $null, [bool]$AllowFresh = $false) {
    if (-not (Test-DatabaseVolumeIsEmpty $Volume)) { return New-RestoreDecision "Keep" }
    if ($AllowFresh) { return New-RestoreDecision "Fresh" }
    $rejected = @()
    foreach ($dump in (Get-CompleteDumps $Folder $Pattern)) {
        $reason = if ($GetRejection) { "$(& $GetRejection $dump)" } else { "" }
        if (-not $reason) { return New-RestoreDecision "Restore" $dump $rejected }
        $rejected += [pscustomobject]@{ Name = $dump.Name; Reason = $reason }
    }
    if ($rejected.Count -gt 0) { return New-RestoreDecision "Refuse" $null $rejected }
    return New-RestoreDecision "Fresh"
}

function New-RestoreDecision([string]$Action, [System.IO.FileInfo]$Dump = $null, [object[]]$Rejected = @()) {
    return [pscustomobject]@{ Action = $Action; Dump = $Dump; Rejected = @($Rejected) }
}

<#
.SYNOPSIS
The lines to print when a decision is Refuse: every rejected dump with its reason, and the way on.
#>
function Format-RestoreRefusal([object]$Decision, [string]$Volume, [string]$FolderName, [string]$Verb) {
    $lines = @("The database volume $Volume is empty, but no dump in $FolderName can be restored:")
    foreach ($rejection in $Decision.Rejected) { $lines += "  $($rejection.Name): $($rejection.Reason)" }
    $lines += "Nothing was started. Put a good dump into $FolderName (from the array or Kopia) and run $Verb again,"
    $lines += "or start with an empty database on purpose: .\docker-compose.ps1 $Verb -Fresh"
    return $lines
}
