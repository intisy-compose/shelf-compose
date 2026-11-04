# Dot-source after data-on-disk.ps1: Assert-DatabaseKey needs Test-DatabaseVolumeIsEmpty and Get-CompleteDumps.

<#
.SYNOPSIS
Makes sure the pgsodium root key exists on disk before the database starts.
.NOTES
The key is bind-mounted into the db container. A key generated while the database volume already
holds a cluster, or while dumps exist that were made with the old key, would not decrypt them and
would silently replace the lost one, so this throws instead and leaves the file absent. That holds
for a deliberate `up -Fresh` too: the dumps are still needed later. A new key is 64 lowercase hex
characters with no newline. It is written beside the key and moved there only once whole, and a key
file of any other shape is refused, so a cut-short write never becomes the database's key.
#>
function Assert-DatabaseKey([string]$KeyPath, [string]$Volume, [string]$BackupsFolder = "", [string]$DumpPattern = "shelf-*.dump") {
    if (Test-Path -LiteralPath $KeyPath -PathType Leaf) {
        if (Test-WholeDatabaseKey $KeyPath) { return }
        throw "$KeyPath is not a 64-character hex key (it holds $((Get-Item -LiteralPath $KeyPath).Length) bytes); a write may have been cut short. Put the original pgsodium_root.key there, or remove the file when the database volume is empty and there are no dumps."
    }
    if (Test-Path -LiteralPath $KeyPath -PathType Container) {
        throw "$KeyPath is a folder, not the encryption key file. Docker creates that folder when it starts the database without the key; remove it and put the key file there (or remove it alone when the database volume is empty and there are no dumps)."
    }
    if (-not (Test-DatabaseVolumeIsEmpty $Volume)) {
        throw "The encryption key $KeyPath is missing but volume $Volume holds a database. Restore the key file there; a new key cannot decrypt it."
    }
    if ($BackupsFolder -and @(Get-CompleteDumps $BackupsFolder $DumpPattern).Count -gt 0) {
        throw "The encryption key $KeyPath is missing but $BackupsFolder holds database dumps. They can only be restored with the original pgsodium_root.key: put that file at $KeyPath. A new key would not decrypt them, so none is generated, and that includes 'up -Fresh': the dumps are still needed later."
    }
    Write-DatabaseKey $KeyPath
}

function Test-WholeDatabaseKey([string]$Path) {
    return [System.IO.File]::ReadAllText($Path) -cmatch '\A[0-9a-fA-F]{64}\z'
}

<#
.SYNOPSIS
Writes a new key to KeyPath, or leaves nothing there and throws when it cannot be written.
#>
function Write-DatabaseKey([string]$KeyPath) {
    $temporary = "$KeyPath.tmp"
    try {
        New-Item -ItemType Directory -Force (Split-Path -Parent $KeyPath) | Out-Null
        $buffer = New-Object byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
        [System.IO.File]::WriteAllText($temporary, (-join ($buffer | ForEach-Object { $_.ToString("x2") })))
        if (-not (Test-WholeDatabaseKey $temporary)) { throw "the written key is not whole" }
        Move-Item -LiteralPath $temporary -Destination $KeyPath
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        throw "The encryption key $KeyPath could not be written; nothing was started. ($($_.Exception.Message))"
    }
}
