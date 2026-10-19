$stackRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $stackRoot "scripts\data-on-disk.ps1")
. (Join-Path $stackRoot "scripts\database-key.ps1")

function New-TestVolume([string]$Name, [bool]$HoldsDatabase) {
    docker volume create $Name | Out-Null
    if ($HoldsDatabase) {
        docker run --rm -v "${Name}:/v" alpine:3.21 touch /v/PG_VERSION | Out-Null
    }
}

Describe "Assert-DatabaseKey" {
    $emptyVolume = "dod-shelf-test-empty"
    $missingVolume = "dod-shelf-test-missing"
    $filledVolume = "dod-shelf-test-filled"
    $keyFolder = Join-Path ([System.IO.Path]::GetTempPath()) "dod-shelf-test-key"

    BeforeEach {
        $ErrorActionPreference = 'Continue'
        Remove-Item -Recurse -Force $keyFolder -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $keyFolder | Out-Null
        docker volume rm -f $emptyVolume $missingVolume $filledVolume 2>&1 | Out-Null
        New-TestVolume $emptyVolume $false
        New-TestVolume $filledVolume $true
    }

    AfterEach {
        docker volume rm -f $emptyVolume $missingVolume $filledVolume 2>&1 | Out-Null
        Remove-Item -Recurse -Force $keyFolder -ErrorAction SilentlyContinue
    }

    It "creates a 64 character lowercase hex key without newline when the volume is empty" {
        $keyPath = Join-Path $keyFolder "secrets\pgsodium_root.key"
        Assert-DatabaseKey $keyPath $emptyVolume
        $content = [System.IO.File]::ReadAllText($keyPath)
        $content | Should Match '^[0-9a-f]{64}$'
    }

    It "creates a key when the volume does not exist" {
        $keyPath = Join-Path $keyFolder "secrets\pgsodium_root.key"
        Assert-DatabaseKey $keyPath $missingVolume
        [System.IO.File]::ReadAllText($keyPath) | Should Match '^[0-9a-f]{64}$'
    }

    It "throws naming the key file and creates nothing when the volume holds a database" {
        $keyPath = Join-Path $keyFolder "secrets\pgsodium_root.key"
        { Assert-DatabaseKey $keyPath $filledVolume } | Should Throw "pgsodium_root.key"
        Test-Path $keyPath | Should Be $false
    }

    foreach ($volume in @($emptyVolume, $filledVolume)) {
        It "leaves an existing key byte-identical (volume $volume)" {
            $keyPath = Join-Path $keyFolder "pgsodium_root.key"
            [System.IO.File]::WriteAllText($keyPath, ("ab" * 32))
            $before = (Get-FileHash $keyPath).Hash
            Assert-DatabaseKey $keyPath $volume
            (Get-FileHash $keyPath).Hash | Should Be $before
        }
    }
}
