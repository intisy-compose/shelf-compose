#Requires -Version 5.1
param([string]$Command = "up", [switch]$Fresh)

# $args, not ValueFromRemainingArguments, so -Switch tokens still bind when forwarded.
$forwarded = $args

Set-StrictMode -Version Latest

# The pinned `name:` must win, because the restore guard checks the volume by that name.
Remove-Item Env:\COMPOSE_PROJECT_NAME -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot "scripts\data-on-disk.ps1")
. (Join-Path $PSScriptRoot "scripts\prove-data.ps1")
. (Join-Path $PSScriptRoot "scripts\database-key.ps1")

$configFile  = Join-Path $PSScriptRoot "config.env"
$exampleFile = Join-Path $PSScriptRoot "config.env.example"
$composeArgs = @("--env-file", $configFile)
$databaseVolume = "shelf-compose_shelf-db"
$secretNames = @("POSTGRES_PASSWORD", "JWT_SECRET", "SESSION_SECRET", "INVITE_TOKEN_SECRET", "FINGERPRINT")

function Write-Step([string]$msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "  $msg" -ForegroundColor Green }
function Write-Err([string]$msg)  { Write-Host $msg -ForegroundColor Red }

function Show-Usage([hashtable]$Commands) {
    $width = ($Commands.Keys | Measure-Object -Property Length -Maximum).Maximum
    Write-Host "Usage: .\docker-compose.ps1 [$(($Commands.Keys | Sort-Object) -join '|')]"
    foreach ($cmd in $Commands.Keys | Sort-Object) {
        Write-Host ("  {0}  {1}" -f $cmd.PadRight($width), $Commands[$cmd])
    }
}

function Read-Config {
    $values = @{}
    if (-not (Test-Path $configFile)) { return $values }
    foreach ($line in Get-Content $configFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { $values[$Matches[1]] = $Matches[2].Trim('"') }
    }
    return $values
}

function Assert-Config {
    if (-not (Test-Path $configFile)) {
        Write-Err "No config.env - run '.\docker-compose.ps1 init-config' first."; exit 1
    }
    $config = Read-Config
    $missing = @($secretNames + @("ANON_KEY", "SERVICE_ROLE_KEY") | Where-Object { -not $config[$_] })
    if ($missing) { Write-Err "config.env is missing: $($missing -join ', ') - run init-config."; exit 1 }
}

function New-Secret([int]$Bytes = 32) {
    $buffer = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    return -join ($buffer | ForEach-Object { $_.ToString("x2") })
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-SupabaseKey([string]$Role, [string]$Secret) {
    $issuedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header  = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"HS256","typ":"JWT"}'))
    $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes(
        "{""role"":""$Role"",""iss"":""supabase"",""iat"":$issuedAt,""exp"":$($issuedAt + 10 * 365 * 24 * 3600)}"))
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 (, [Text.Encoding]::UTF8.GetBytes($Secret))
    $signature = ConvertTo-Base64Url ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("$header.$payload")))
    return "$header.$payload.$signature"
}

function Initialize-Config {
    if (-not (Test-Path $configFile)) { Copy-Item $exampleFile $configFile }
    $config = Read-Config
    $generated = @{}
    foreach ($name in $secretNames) { if (-not $config[$name]) { $generated[$name] = New-Secret } }
    $jwtSecret = if ($generated.ContainsKey("JWT_SECRET")) { $generated["JWT_SECRET"] } else { $config["JWT_SECRET"] }
    if ($generated.ContainsKey("JWT_SECRET") -or -not $config["ANON_KEY"]) { $generated["ANON_KEY"] = New-SupabaseKey "anon" $jwtSecret }
    if ($generated.ContainsKey("JWT_SECRET") -or -not $config["SERVICE_ROLE_KEY"]) { $generated["SERVICE_ROLE_KEY"] = New-SupabaseKey "service_role" $jwtSecret }
    if (-not $generated.Count) { Write-OK "config.env already has every secret; nothing changed."; return }
    Set-ConfigValues $generated
    Write-OK "Generated $(($generated.Keys | Sort-Object) -join ', ') in config.env."
}

function Set-ConfigValues([hashtable]$Values) {
    $lines = foreach ($line in Get-Content $configFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=' -and $Values.ContainsKey($Matches[1])) { "$($Matches[1])=$($Values[$Matches[1]])" }
        else { $line }
    }
    [System.IO.File]::WriteAllText($configFile, (($lines -join "`n") + "`n"))
}

function Get-TailnetStatus {
    $raw = docker compose @composeArgs exec -T tailscale tailscale --socket=/var/run/tailscale/tailscaled.sock status --json 2>$null
    if (-not $raw) { return $null }
    try { return ($raw | Out-String | ConvertFrom-Json) } catch { return $null }
}

# The ts.net name is only known once the node has joined, and every other service is configured
# from it, so the tailscale container starts first and the URLs are written before the rest.
function Connect-Tailnet {
    $config = Read-Config
    $joined = Test-Path (Join-Path $PSScriptRoot "data\tailscale\tailscaled.state")
    if (-not $config["TS_AUTHKEY"] -and -not $joined) {
        Write-Err "TS_AUTHKEY is empty in config.env and this node has not joined the tailnet yet."
        Write-Err "Create a key at https://login.tailscale.com/admin/settings/keys"
        exit 1
    }
    Write-Step "Joining the tailnet..."
    docker compose @composeArgs up -d tailscale
    $deadline = (Get-Date).AddSeconds(90)
    $tailnetHost = $null
    while ((Get-Date) -lt $deadline) {
        $status = Get-TailnetStatus
        if ($status -and $status.BackendState -eq "Running" -and $status.Self.DNSName) { $tailnetHost = $status.Self.DNSName.TrimEnd('.'); break }
        Start-Sleep -Seconds 2
    }
    if (-not $tailnetHost) {
        Write-Err "The node did not join within 90s. An expired or used-up TS_AUTHKEY is the usual cause;"
        Write-Err "check '.\docker-compose.ps1 logs tailscale'."
        exit 1
    }
    Write-OK "Joined as $tailnetHost"
    if ($config["SHELF_HOST"] -ne $tailnetHost) {
        Set-ConfigValues @{ SHELF_HOST = $tailnetHost; SERVER_URL = "https://$tailnetHost"; SUPABASE_URL = "https://${tailnetHost}:8443" }
        Write-OK "Wrote SHELF_HOST, SERVER_URL and SUPABASE_URL to config.env."
    }
}

function Confirm-DatabaseKey {
    try { Assert-DatabaseKey (Join-Path $PSScriptRoot "data\secrets\pgsodium_root.key") $databaseVolume (Join-Path $PSScriptRoot "data\backups") "shelf-*.dump" }
    catch { Write-Err $_.Exception.Message; exit 1 }
}

function Show-Urls {
    $config = Read-Config
    Write-Host ""
    Write-Host "  shelf          : $($config['SERVER_URL'])   (from any device on your tailnet)"
    Write-Host "                   http://localhost:8444   (on this PC)"
    Write-Host "  Supabase       : $($config['SUPABASE_URL'])"
    Write-Host "  Mail (Mailpit) : http://localhost:8025   (on this PC only)"
}

function Invoke-PgRestore([string]$File) {
    docker compose @composeArgs exec -T db-backup pg_restore -h db -U supabase_admin -d postgres --clean --if-exists "/backups/$File" | Out-Host
    return $LASTEXITCODE
}

function Get-RunningServices {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return @(docker compose @composeArgs ps --status running --services 2>$null) }
    finally { $ErrorActionPreference = $previousPreference }
}

<#
.SYNOPSIS
Exits 1 unless db and db-backup are running.
.NOTES
With the stack down, the restore would fail at the exec and the trailing `up -d` would then start
the whole stack on an empty database.
#>
function Assert-RestoreServicesRunning {
    $running = Get-RunningServices
    $missing = @("db", "db-backup") | Where-Object { $_ -notin $running }
    if (-not $missing) { return }
    Write-Err "Cannot restore: $($missing -join ', ') not running. Run .\docker-compose.ps1 up first, or .\docker-compose.ps1 up -Fresh and then restore."
    exit 1
}

function Invoke-Restore([object[]]$RestoreArguments) {
    Assert-RestoreServicesRunning
    $file = if ($RestoreArguments) { "$($RestoreArguments[0])" } else { "" }
    if (-not $file) {
        $latest = Get-CompleteDumps (Join-Path $PSScriptRoot "data\backups") "shelf-*.dump" |
            Where-Object { Test-DumpIsRestorable $_ } | Select-Object -First 1
        if (-not $latest) { Write-Err "No backups in data\backups."; exit 1 }
        $file = $latest.Name
    }
    $file = Split-Path $file -Leaf
    Write-Step "Restoring $file (shelf, auth and storage are stopped meanwhile)..."
    docker compose @composeArgs stop shelf gateway auth storage
    $restoreExit = Invoke-PgRestore $file
    if ($restoreExit -ne 0) {
        Write-Err "pg_restore reported errors (exit $restoreExit); check the output above. shelf, gateway, auth and storage stay stopped."
        exit 1
    }
    docker compose @composeArgs up -d
    Write-OK "Restored $file."
}

<#
.SYNOPSIS
The image of the db-backup service, whose client tools read dumps.
#>
function Get-BackupImage {
    $compose = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "docker-compose.yml")
    if ($compose -notmatch '(?ms)^  db-backup:.*?^    image:\s*(\S+)') { throw "no image found for the db-backup service" }
    return $Matches[1]
}

<#
.SYNOPSIS
Why the dump cannot be restored, or an empty string when pg_restore can list it and it holds table data.
.NOTES
Runs in a throwaway container of the stack's own postgres client image with data/backups mounted
read-only, so it works while the stack is down. An empty database dumps to a valid file with no table data.
#>
function Get-DumpRejection([System.IO.FileInfo]$Dump) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $listing = docker run --rm -v "$($Dump.DirectoryName):/backups:ro" (Get-BackupImage) pg_restore --list "/backups/$($Dump.Name)" 2>$null
        if ($LASTEXITCODE -ne 0) { return "pg_restore cannot list it (exit $LASTEXITCODE)" }
        if (-not ($listing | Where-Object { $_ -match "TABLE DATA" })) { return "it holds no table data" }
        return ""
    }
    finally { $ErrorActionPreference = $previousPreference }
}

function Test-DumpIsRestorable([System.IO.FileInfo]$Dump) {
    return -not (Get-DumpRejection $Dump)
}

function Format-DumpAge([datetime]$WrittenAt) {
    $age = (Get-Date) - $WrittenAt
    if ($age.TotalHours -ge 24) { return "{0} d {1} h old" -f [int]$age.Days, [int]$age.Hours }
    if ($age.TotalHours -ge 1) { return "{0} h {1} min old" -f [int]$age.Hours, [int]$age.Minutes }
    return "{0} min old" -f [int]$age.TotalMinutes
}

<#
.SYNOPSIS
What to do with the database volume; exits 1 before anything starts when the answer is Refuse.
#>
function Confirm-RestoreDecision([string]$Verb) {
    $decision = Get-RestoreDecision $databaseVolume (Join-Path $PSScriptRoot "data\backups") "shelf-*.dump" { param($dump) Get-DumpRejection $dump } $Fresh.IsPresent
    if ($decision.Action -eq "Refuse") {
        Format-RestoreRefusal $decision $databaseVolume "data\backups" $Verb | ForEach-Object { Write-Err $_ }
        exit 1
    }
    if ($decision.Action -eq "Fresh" -and $Fresh) {
        Write-Step "Starting with an empty database (-Fresh)."
        Write-FreshDumpWarning
    }
    return $decision
}

function Write-FreshDumpWarning {
    if (@(Get-CompleteDumps (Join-Path $PSScriptRoot "data\backups") "shelf-*.dump").Count -eq 0) { return }
    Write-Err "Warning: the hourly dumps of the empty database rotate the old dumps out after BACKUP_KEEP hours unless '.\docker-compose.ps1 restore <file>' runs first."
}

function Wait-DatabaseReachable {
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        docker compose @composeArgs exec -T db-backup pg_isready -h db -U supabase_admin -d postgres | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-EmptyDatabaseRestore([string]$DumpName) {
    docker compose @composeArgs up -d db db-backup | Out-Host
    if ($LASTEXITCODE -ne 0) { return "The database did not start." }
    if (-not (Wait-DatabaseReachable)) { return "The database did not become reachable within 120 s." }
    $restoreExit = Invoke-PgRestore $DumpName
    if ($restoreExit -ne 0) { return "pg_restore reported errors (exit $restoreExit); check the output above." }
    return ""
}

<#
.SYNOPSIS
Stops the stack and removes the database volume after a failed restore into it, then exits 1.
.NOTES
The volume was empty before this run, so removing it loses nothing, and the next `up` finds it empty
again and retries instead of keeping a half-restored database.
#>
function Undo-FailedRestore([string]$Failure, [string]$DumpName) {
    Write-Err $Failure
    Write-Step "Stopping the stack and removing $databaseVolume, which was empty before this run..."
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        docker compose @composeArgs down
        docker volume rm $databaseVolume | Out-Null
        $volumeRemoved = $LASTEXITCODE -eq 0
    }
    finally { $ErrorActionPreference = $previousPreference }
    if (-not $volumeRemoved) { Write-Err "Could not remove $databaseVolume; remove it (docker volume rm $databaseVolume) before the next up." }
    Write-Err "Restoring $DumpName failed. Run .\docker-compose.ps1 up to try again, or start empty and restore by hand:"
    Write-Err "  .\docker-compose.ps1 up -Fresh   then   .\docker-compose.ps1 restore $DumpName"
    exit 1
}

<#
.SYNOPSIS
Restores the decision's dump into the empty database before anything else starts.
.NOTES
Only db and db-backup run meanwhile, so migrate, auth and storage first meet the restored schema
instead of initialising one the restore then drops.
#>
function Restore-EmptyDatabase([object]$Decision) {
    if ($Decision.Action -ne "Restore") { return }
    $dump = $Decision.Dump
    foreach ($rejection in $Decision.Rejected) { Write-Host "  skipping $($rejection.Name): $($rejection.Reason)" -ForegroundColor Gray }
    Write-Step "Restoring $($dump.Name) ($(Format-DumpAge $dump.LastWriteTime)) into the empty database..."
    $failure = Invoke-EmptyDatabaseRestore $dump.Name
    if ($failure) { Undo-FailedRestore $failure $dump.Name }
    Write-OK "Restored $($dump.Name)."
}

function Invoke-Up {
    Confirm-DatabaseKey
    Assert-Config
    $decision = Confirm-RestoreDecision "up"
    Connect-Tailnet
    Restore-EmptyDatabase $decision
    Write-Step "Starting shelf..."
    docker compose @composeArgs up -d
    if ($LASTEXITCODE -eq 0) { Show-Urls }
}

function Invoke-Recreate([string]$Verb) {
    Confirm-DatabaseKey
    Assert-Config
    $decision = Confirm-RestoreDecision $Verb
    Connect-Tailnet
    Restore-EmptyDatabase $decision
    if ($Verb -eq "rebuild") {
        Write-Step "Rebuilding..."
        docker compose @composeArgs build
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }
    Write-Step "Recreating..."
    docker compose @composeArgs up -d --force-recreate
    Show-Urls
}

function Invoke-Backup {
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    $file = "shelf-$stamp.dump"
    Write-Step "Dumping the database to data\backups\$file..."
    docker compose @composeArgs exec -T db-backup sh -c "pg_dump -h db -U supabase_admin -d postgres -Fc -f /backups/$file.tmp && mv /backups/$file.tmp /backups/$file"
    if ($LASTEXITCODE -ne 0) { Write-Err "Backup failed."; exit 1 }
    Write-OK "Backed up to data\backups\$file."
}

function Invoke-Data([object[]]$DataArguments) {
    $subcommand = if ($DataArguments) { "$($DataArguments[0])".ToLower() } else { "status" }
    switch ($subcommand) {
        "status" { git -C $PSScriptRoot submodule status -- data; break }
        "use" {
            $source = if ($DataArguments.Count -ge 2) { "$($DataArguments[1])" } else { "" }
            if ($source) {
                $parts = $source.Split("@", 2)
                $url = if ($parts[0] -match "://|^git@") { $parts[0] } else { "https://github.com/$($parts[0]).git" }
                $ref = if ($parts.Count -eq 2) { $parts[1] } else { "main" }
            } else {
                $url = git -C $PSScriptRoot config -f .gitmodules submodule.data.url
                $ref = "main"
            }
            Write-Step "Pointing data at $url @ $ref"
            if (-not (Test-Path "$PSScriptRoot\data\.git")) { git -C $PSScriptRoot submodule update --init -- data 2>$null | Out-Null }
            git -C $PSScriptRoot config submodule.data.url $url
            git -C "$PSScriptRoot\data" remote set-url origin $url
            git -C "$PSScriptRoot\data" fetch -q origin $ref
            git -C "$PSScriptRoot\data" checkout -q FETCH_HEAD
            Write-OK "data now at $(git -C "$PSScriptRoot\data" rev-parse --short HEAD)"
            break
        }
        default { Show-Usage -Commands $usage; exit 1 }
    }
}

$usage = @{
    "init-config" = "Create config.env and generate every missing secret and key"
    "up"          = "[-Fresh]  join the tailnet, restore an empty database from data\backups, start the stack (default); -Fresh starts it empty instead"
    "url"         = "Print the tailnet URLs"
    "down"        = "Stop and remove the containers (the database volume and data/ stay)"
    "restart"     = "[-Fresh]  recreate the stack, restoring an empty database as up does"
    "rebuild"     = "[-Fresh]  rebuild the built images (shelf, migrate) and recreate the stack, restoring as up does"
    "status"      = "Show the containers and their health"
    "logs"        = "[service]  follow logs, e.g. logs shelf"
    "backup"      = "Dump the database to data\backups now"
    "restore"     = "[file]  restore the database from data\backups (newest by default)"
    "prove-data"  = "DESTRUCTIVE: dump, delete every volume, start, and compare every table (needs the stack up)"
    "data"        = "status | use [owner/repo[@ref]]  point data/ at a data repo (none = template)"
    "catalog"     = "check | sync [--prune] | add <file> | update <file> | list | images | cutout <photo> <png>  (see CATALOG.md in data/)"
}

Set-Location $PSScriptRoot

switch ($Command.ToLower()) {
    "init-config" { Initialize-Config; break }
    "up"      { Invoke-Up; break }
    "down"    { Write-Step "Stopping everything..."; docker compose @composeArgs down; break }
    "restart" { Invoke-Recreate "restart"; break }
    "rebuild" { Invoke-Recreate "rebuild"; break }
    "url"     { Show-Urls; break }
    "status"  { docker compose @composeArgs ps -a; break }
    "logs"    { docker compose @composeArgs logs -f @forwarded; break }
    "backup"  { Assert-Config; Invoke-Backup; break }
    "restore" { Assert-Config; Invoke-Restore $forwarded; break }
    "prove-data" { Assert-Config; Invoke-ProveData; break }
    "data"    { Invoke-Data $forwarded; break }
    "catalog" { Assert-Config; & python (Join-Path $PSScriptRoot "scripts\catalog.py") @forwarded; exit $LASTEXITCODE }
    default   { Show-Usage -Commands $usage; exit 1 }
}
