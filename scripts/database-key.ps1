# Dot-source after data-on-disk.ps1: Assert-DatabaseKey needs Test-DatabaseVolumeIsEmpty.

<#
.SYNOPSIS
Makes sure the pgsodium root key exists on disk before the database starts.
.NOTES
The key is bind-mounted into the db container. A key generated while the database volume already
holds a cluster would not decrypt that cluster and would silently replace the lost one, so this
throws instead and leaves the file absent. A new key is 64 lowercase hex characters with no newline.
#>
function Assert-DatabaseKey([string]$KeyPath, [string]$Volume) {
    if (Test-Path -LiteralPath $KeyPath) { return }
    if (-not (Test-DatabaseVolumeIsEmpty $Volume)) {
        throw "The encryption key $KeyPath is missing but volume $Volume holds a database. Restore the key file there; a new key cannot decrypt it."
    }
    $keyFolder = Split-Path -Parent $KeyPath
    New-Item -ItemType Directory -Force $keyFolder | Out-Null
    $buffer = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    $hexKey = -join ($buffer | ForEach-Object { $_.ToString("x2") })
    [System.IO.File]::WriteAllText($KeyPath, $hexKey)
}
