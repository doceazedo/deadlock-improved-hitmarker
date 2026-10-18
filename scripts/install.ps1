param(
    [string]$Game,
    [switch]$NoSound,
    [ValidateRange(0, 99)][int]$Pak = 0
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
$DistVpk = Get-DistVpk $NoSound

$GameInfoEncoding = [Text.Encoding]::GetEncoding(28591)
$RequiredSearchPaths = @(
    @("Mod", "citadel"),
    @("Mod", "core"),
    @("Write", "citadel"),
    @("Game", "citadel/addons")
)

function Find-BlockEnd([string]$Text, [int]$Start) {
    $depth = 0
    $index = $Text.IndexOf("{", $Start)
    while ($index -ge 0 -and $index -lt $Text.Length) {
        if ($Text.Substring($index).StartsWith("//")) {
            $index = $Text.IndexOf("`n", $index)
            continue
        }
        $character = $Text[$index]
        if ($character -eq "{") {
            $depth++
        } elseif ($character -eq "}") {
            $depth--
            if ($depth -eq 0) {
                return $index + 1
            }
        }
        $index++
    }
    throw "unbalanced braces in gameinfo.gi"
}

function Update-GameInfo([string]$Text) {
    $changed = $false
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }

    foreach ($pair in $RequiredSearchPaths) {
        $key = $pair[0]
        $value = $pair[1]
        $existing = [regex]::new("^[ \t]*" + $key + "[ \t]+" + [regex]::Escape($value) + "[ \t]*\r?$", "Multiline")
        if ($existing.IsMatch($Text)) {
            continue
        }
        $citadel = [regex]::new("^([ \t]*)Game([ \t]+)citadel[ \t]*(\r?)$", "Multiline").Match($Text)
        if (-not $citadel.Success) {
            throw "could not find 'Game citadel' search path"
        }
        $padding = "`t" * [math]::Max(1, 4 - [math]::Floor($key.Length / 4))
        $line = $citadel.Groups[1].Value + $key + $padding + $value + $citadel.Groups[3].Value + "`n"
        $Text = $Text.Insert($citadel.Index, $line)
        $changed = $true
    }

    if (-not [regex]::IsMatch($Text, "^[ \t]*AddonConfig\b", "Multiline")) {
        $fileSystem = [regex]::new("^([ \t]*)FileSystem[ \t]*\r?\n", "Multiline").Match($Text)
        if (-not $fileSystem.Success) {
            throw "could not find FileSystem block"
        }
        $indent = $fileSystem.Groups[1].Value
        $end = Find-BlockEnd $Text ($fileSystem.Index + $fileSystem.Length)
        $block = $newline + $newline + $indent + "AddonConfig" + $newline + $indent + "{" + $newline + $indent + "`t`"UseOfficialAddons`"`t`"1`"" + $newline + $indent + "}"
        $Text = $Text.Insert($end, $block)
        $changed = $true
    }

    return [pscustomobject]@{ Text = $Text; Changed = $changed }
}

function Install-GameInfoPatch([string]$Citadel) {
    $gameInfo = Join-Path $Citadel "gameinfo.gi"
    $result = Update-GameInfo ([IO.File]::ReadAllText($gameInfo, $GameInfoEncoding))
    if (-not $result.Changed) {
        Write-Host "already patched $gameInfo"
        return
    }
    $backup = Join-Path $Citadel "gameinfo.gi.hitfeedback-backup"
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $gameInfo -Destination $backup
    }
    try {
        [IO.File]::WriteAllText($gameInfo, $result.Text, $GameInfoEncoding)
    } catch [System.IO.IOException], [System.UnauthorizedAccessException] {
        throw "cannot write $gameInfo, close Deadlock and try again"
    }
    Write-Host "patched $gameInfo"
    Write-Host "backup at $backup"
}

function Test-ModVpk([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = New-Object IO.BinaryReader $stream
        if ($stream.Length -lt 12 -or $reader.ReadUInt32() -ne 0x55AA1234) {
            return $false
        }
        $version = $reader.ReadUInt32()
        $treeSize = $reader.ReadUInt32()
        $stream.Position = if ($version -eq 2) { 28 } else { 12 }
        $tree = [Text.Encoding]::ASCII.GetString($reader.ReadBytes([int][math]::Min($treeSize, $stream.Length)))
        return $tree.Contains("sounds/$ModName") -or $tree.Contains("$ModName`0")
    } finally {
        $stream.Dispose()
    }
}

function Get-InstallTarget([string]$Addons, [int]$Requested) {
    if ($Requested -gt 0) {
        return Join-Path $Addons ("pak{0:D2}_dir.vpk" -f $Requested)
    }
    $existing = @(Get-ChildItem -LiteralPath $Addons -File | Where-Object { $_.Name -match '^pak\d{2}_dir\.vpk$' -and (Test-ModVpk $_.FullName) })
    if ($existing.Count -gt 1) {
        throw "found this mod in several slots ($(($existing.Name) -join ', ')); remove the extras or pass -Pak"
    }
    if ($existing.Count -eq 1) {
        return $existing[0].FullName
    }
    $occupied = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $Addons -File)) {
        if ($file.Name -match '^pak(\d{2})_(?:dir|\d{3})\.vpk$') {
            $occupied[[int]$matches[1]] = $true
        }
    }
    for ($number = 1; $number -le 99; $number++) {
        if (-not $occupied.ContainsKey($number)) {
            return Join-Path $Addons ("pak{0:D2}_dir.vpk" -f $number)
        }
    }
    throw "all addon slots pak01 through pak99 are taken"
}

if (-not (Test-Path -LiteralPath $DistVpk)) {
    throw "missing $DistVpk, run scripts/build.ps1 first"
}
if (Get-Process -Name "deadlock", "project8" -ErrorAction SilentlyContinue) {
    throw "close Deadlock before installing"
}

$citadel = Join-Path (Resolve-DeadlockRoot $Game) "game\citadel"
$addons = Join-Path $citadel "addons"
New-Item -ItemType Directory -Force -Path $addons | Out-Null
$target = Get-InstallTarget $addons $Pak
Copy-Item -LiteralPath $DistVpk -Destination $target -Force
Write-Host "installed $target"
Install-GameInfoPatch $citadel
