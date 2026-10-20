# Dot-source after data-on-disk.ps1: Assert-DatabaseKey needs Test-DatabaseVolumeIsEmpty and Get-CompleteDumps.

<#
.SYNOPSIS
Makes sure the pgsodium root key exists on disk before the database starts.
.NOTES
The key is bind-mounted into the db container. A key generated while the database volume already
holds a cluster, or while dumps exist that were made with the old key, would not decrypt them and
would silently replace the lost one, so this throws instead and leaves the file absent. That holds
for a deliberate `up -Fresh` too: the dumps are still needed later. A new key is 64 lowercase hex
characters with no newline.
#>
function Assert-DatabaseKey([string]$KeyPath, [string]$Volume, [string]$BackupsFolder = "", [string]$DumpPattern = "shelf-*.dump") {
    if (Test-Path -LiteralPath $KeyPath -PathType Leaf) { return }
    if (Test-Path -LiteralPath $KeyPath -PathType Container) {
        throw "$KeyPath is a folder, not the encryption key file. Docker creates that folder when it starts the database without the key; remove it and put the key file there (or remove it alone when the database volume is empty and there are no dumps)."
    }
    if (-not (Test-DatabaseVolumeIsEmpty $Volume)) {
        throw "The encryption key $KeyPath is missing but volume $Volume holds a database. Restore the key file there; a new key cannot decrypt it."
    }
    if ($BackupsFolder -and @(Get-CompleteDumps $BackupsFolder $DumpPattern).Count -gt 0) {
        throw "The encryption key $KeyPath is missing but $BackupsFolder holds database dumps. They can only be restored with the original pgsodium_root.key: put that file at $KeyPath. A new key would not decrypt them, so none is generated, and that includes 'up -Fresh': the dumps are still needed later."
    }
    $keyFolder = Split-Path -Parent $KeyPath
    New-Item -ItemType Directory -Force $keyFolder | Out-Null
    $buffer = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    $hexKey = -join ($buffer | ForEach-Object { $_.ToString("x2") })
    [System.IO.File]::WriteAllText($KeyPath, $hexKey)
}
