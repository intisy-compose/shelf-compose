# The shared gateway from intisy-compose/workflows gateway/, vendored byte for byte. Dot-sourced by a
# stack's docker-compose.ps1, whose delete removes the stack's node from the tailnet with it. The bash
# twin is tailnet-node.sh, with the same messages.

$TailnetMachinesPage = "https://login.tailscale.com/admin/machines"
$TailnetApi = "https://api.tailscale.com/api/v2"

function Write-TailnetStep([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-TailnetOK([string]$Message)   { Write-Host "  $Message" -ForegroundColor Green }
function Write-TailnetErr([string]$Message)  { Write-Host $Message -ForegroundColor Red }

function ConvertFrom-Base64Text([string]$Text) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

<#
.SYNOPSIS
The stable node ID of the current profile in a tailscaled.state, or $null when the state names none.
.NOTES
The ID, never the name, picks the node: another device may carry the same name.
#>
function Get-TailnetNodeId([string]$StateText) {
    try {
        $state = $StateText | ConvertFrom-Json
        $current = ConvertFrom-Base64Text $state.'_current-profile'
        $profiles = ConvertFrom-Base64Text $state.'_profiles' | ConvertFrom-Json
        foreach ($loginProfile in $profiles.PSObject.Properties.Value) {
            if ($loginProfile.Key -ne $current) { continue }
            $node = "$($loginProfile.NodeID)"
            if ($node -cmatch '^[A-Za-z0-9]+$') { return $node }
            return $null
        }
    }
    catch { }
    return $null
}

function Get-TailnetApiToken([string]$ConfigPath) {
    $token = ""
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $token }
    foreach ($line in Get-Content -LiteralPath $ConfigPath) {
        if ($line -cmatch '^\s*TS_API_TOKEN\s*=(.*)$') { $token = $Matches[1].Trim().Trim('"') }
    }
    return $token
}

function Write-TailnetManualStep([string]$NodeName, [string]$NodeId) {
    Write-TailnetErr "  Remove $NodeName (node ID $NodeId) on the Machines page: $TailnetMachinesPage"
}

<#
.SYNOPSIS
The HTTP status of the API's DELETE of the device, or 0 when nothing answered.
.NOTES
The token stays in this process's memory as a header, so it is on no command line. PowerShell 5.1 does
not offer TLS 1.2 by default on every .NET 4 runtime, and the API needs it. Both PowerShell 5.1 and 7
throw for an error status and carry it in the exception's Response.
#>
function Get-TailnetDeleteStatus([string]$NodeId, [string]$Token) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Delete -TimeoutSec 30 -Uri "$TailnetApi/device/$NodeId" -Headers @{ Authorization = "Bearer $Token" }
        return [int]$response.StatusCode
    }
    catch {
        $answer = $_.Exception.PSObject.Properties["Response"]
        if (-not $answer -or -not $answer.Value) { return 0 }
        return [int]$answer.Value.StatusCode
    }
}

<#
.SYNOPSIS
Removes the node with that stable ID through the Tailscale API with the TS_API_TOKEN of the config file.
.OUTPUTS
"gone" when the node is gone, "manual" when there is no token (the manual step is printed instead),
"failed" when the API did not remove it.
#>
function Remove-TailnetNode([string]$NodeId, [string]$NodeName, [string]$ConfigPath) {
    $configName = Split-Path -Leaf $ConfigPath
    $token = Get-TailnetApiToken $ConfigPath
    if (-not $token) {
        Write-TailnetErr "No TS_API_TOKEN in $configName, so $NodeName stays in the tailnet."
        Write-TailnetManualStep $NodeName $NodeId
        return "manual"
    }
    if ($token -cnotmatch '^[A-Za-z0-9_-]+$') {
        Write-TailnetErr "TS_API_TOKEN in $configName is not a Tailscale API token, so $NodeName was not removed."
        Write-TailnetManualStep $NodeName $NodeId
        return "failed"
    }
    Write-TailnetStep "Removing $NodeName (node ID $NodeId) from the tailnet..."
    $code = Get-TailnetDeleteStatus $NodeId $token
    if ($code -in 200, 204) {
        Write-TailnetOK "Removed $NodeName from the tailnet."
        return "gone"
    }
    if ($code -eq 404) {
        Write-TailnetOK "The tailnet has no node $NodeId any more, so there is nothing to remove."
        Write-TailnetOK "If $NodeName is still listed, the token is for another tailnet: remove it on $TailnetMachinesPage"
        return "gone"
    }
    if ($code -eq 0) { Write-TailnetErr "The Tailscale API did not answer, so $NodeName was not removed." }
    elseif ($code -in 401, 403) { Write-TailnetErr "The Tailscale API refused TS_API_TOKEN (HTTP $code): it has expired or may not remove devices, so $NodeName was not removed." }
    else { Write-TailnetErr "The Tailscale API answered HTTP $code, so $NodeName was not removed." }
    Write-TailnetManualStep $NodeName $NodeId
    return "failed"
}

<#
.SYNOPSIS
The tailnet half of a stack's delete, for a stack whose node state is the folder: removes the node the
state identifies, then the folder, so a later up joins fresh. $false when it removed nothing.
.NOTES
The folder stays whenever its node may still be in the tailnet and the API can still remove it: an API
error, or a state that names no node.
#>
function Remove-TailnetIdentity([string]$StateFolder, [string]$NodeName, [string]$ConfigPath) {
    if (-not $StateFolder) { throw "Remove-TailnetIdentity needs the tailnet state folder" }
    $stateFile = Join-Path $StateFolder "tailscaled.state"
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        Write-TailnetOK "No node identity in $StateFolder, so no node is removed from the tailnet."
        if (Test-Path -LiteralPath $StateFolder) { Remove-Item -LiteralPath $StateFolder -Recurse -Force }
        return $true
    }
    $nodeId = Get-TailnetNodeId (Get-Content -LiteralPath $stateFile -Raw)
    if (-not $nodeId) {
        Write-TailnetErr "$stateFile names no node, so none is removed and $StateFolder is kept."
        Write-TailnetErr "  Remove $NodeName on the Machines page, $TailnetMachinesPage, then delete $StateFolder."
        return $false
    }
    if ((Remove-TailnetNode $nodeId $NodeName $ConfigPath) -eq "failed") {
        Write-TailnetErr "$StateFolder is kept, so delete can run again."
        return $false
    }
    Remove-Item -LiteralPath $StateFolder -Recurse -Force
    Write-TailnetOK "Removed $StateFolder; the next up joins the tailnet fresh."
    return $true
}
