#Requires -Version 5.1
param([string]$Command = "up")

# $args, not ValueFromRemainingArguments, so -Switch tokens still bind when forwarded.
$forwarded = $args

Set-StrictMode -Version Latest

$configFile  = Join-Path $PSScriptRoot "config.env"
$exampleFile = Join-Path $PSScriptRoot "config.env.example"
$composeArgs = @("--env-file", $configFile)
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

function Show-Urls {
    $config = Read-Config
    Write-Host ""
    Write-Host "  shelf          : $($config['SERVER_URL'])   (from any device on your tailnet)"
    Write-Host "  Supabase       : $($config['SUPABASE_URL'])"
    Write-Host "  Mail (Mailpit) : http://localhost:$(if ($config['MAILPIT_PORT']) { $config['MAILPIT_PORT'] } else { 8025 })"
}

function Invoke-Restore([object[]]$RestoreArguments) {
    $file = if ($RestoreArguments) { "$($RestoreArguments[0])" } else { "" }
    if (-not $file) {
        $latest = Get-ChildItem (Join-Path $PSScriptRoot "data\backups") -Filter "shelf-*.dump" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latest) { Write-Err "No backups in data\backups."; exit 1 }
        $file = $latest.Name
    }
    $file = Split-Path $file -Leaf
    Write-Step "Restoring $file (shelf, auth and storage are stopped meanwhile)..."
    docker compose @composeArgs stop shelf gateway auth storage
    docker compose @composeArgs exec -T db-backup pg_restore -h db -U supabase_admin -d postgres --clean --if-exists "/backups/$file"
    $restoreExit = $LASTEXITCODE
    docker compose @composeArgs up -d
    if ($restoreExit -ne 0) { Write-Err "pg_restore reported errors (exit $restoreExit); check the output above."; exit 1 }
    Write-OK "Restored $file."
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
    "up"          = "Join the tailnet, then start the stack (default); migrations and buckets run first"
    "url"         = "Print the tailnet URLs"
    "down"        = "Stop and remove the containers (the database volume and data/ stay)"
    "restart"     = "Recreate the stack"
    "rebuild"     = "Rebuild the built images (shelf, migrate) and recreate the stack"
    "status"      = "Show the containers and their health"
    "logs"        = "[service]  follow logs, e.g. logs shelf"
    "backup"      = "Dump the database to data\backups now"
    "restore"     = "[file]  restore the database from data\backups (newest by default)"
    "data"        = "status | use [owner/repo[@ref]]  point data/ at a data repo (none = template)"
    "catalog"     = "check | sync [--prune] | add <file> | update <file> | list  (see CATALOG.md in data/)"
}

Set-Location $PSScriptRoot

switch ($Command.ToLower()) {
    "init-config" { Initialize-Config; break }
    "up"      { Assert-Config; Connect-Tailnet; Write-Step "Starting shelf..."; docker compose @composeArgs up -d; if ($LASTEXITCODE -eq 0) { Show-Urls }; break }
    "down"    { Write-Step "Stopping everything..."; docker compose @composeArgs down; break }
    "restart" { Assert-Config; Connect-Tailnet; Write-Step "Recreating..."; docker compose @composeArgs up -d --force-recreate; Show-Urls; break }
    "rebuild" { Assert-Config; Connect-Tailnet; Write-Step "Rebuilding..."; docker compose @composeArgs build; if ($LASTEXITCODE -ne 0) { exit 1 }; docker compose @composeArgs up -d --force-recreate; Show-Urls; break }
    "url"     { Show-Urls; break }
    "status"  { docker compose @composeArgs ps -a; break }
    "logs"    { docker compose @composeArgs logs -f @forwarded; break }
    "backup"  { Assert-Config; Invoke-Backup; break }
    "restore" { Assert-Config; Invoke-Restore $forwarded; break }
    "data"    { Invoke-Data $forwarded; break }
    "catalog" { Assert-Config; & python (Join-Path $PSScriptRoot "scripts\catalog.py") @forwarded; exit $LASTEXITCODE }
    default   { Show-Usage -Commands $usage; exit 1 }
}
