param(
    [string]$Game,
    [string]$Csdk,
    [string]$S2v,
    [switch]$Install,
    [switch]$NoSound,
    [ValidateRange(0, 99)][int]$Pak = 0
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$DistVpk = Get-DistVpk $NoSound
$Mod = Join-Path $RepoRoot "mod"
$Game = Resolve-DeadlockRoot $Game
$Csdk = Resolve-CsdkRoot $Csdk
$S2v = Resolve-Source2Viewer $S2v
$StockVpk = Join-Path $Game "game\citadel\pak01_dir.vpk"
$Compiler = Join-Path $Csdk "game\bin_cs2\win64\resourcecompiler.exe"
$Packer = Join-Path $Csdk "game\bin\win64\CSDKCfgVPK.exe"
$ContentDir = Join-Path $Csdk "content\citadel_addons\$ModName"
$GameDir = Join-Path $Csdk "game\citadel_addons\$ModName"
$Utf8 = New-Object System.Text.UTF8Encoding $false
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$Silent = "sounds/common/null.vsnd"
$Alignment = 16
$AbilitySound = 'const ABILITY_SOUND = "ImprovedHitmarker.Ability";'
$EventPattern = [regex]::new('^\t([\w.\-]+) = \n\t\{\n(.*?)^\t\}\n', "Multiline, Singleline")
$BasePattern = [regex]::new('^\t\tbase = "([^"]+)"', "Multiline")
$VolumePattern = [regex]::new('^\t\tvolume = (-?[\d.]+)$', "Multiline")

function Invoke-Native([string]$FilePath, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Output = ($output -join "`n"); ExitCode = $code }
}

function Read-Text([string]$Path) {
    return [IO.File]::ReadAllText($Path, $Utf8).Replace("`r`n", "`n")
}

function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}

function Read-ModJson([string]$Name) {
    $path = Join-Path $Mod $Name
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    return [IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json
}

function Get-Pairs($Object) {
    if ($null -eq $Object) {
        return @()
    }
    if ($Object -is [Collections.IDictionary]) {
        return @($Object.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Value = $_.Value } })
    }
    return @($Object.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
}

function Get-RelativePath([string]$Base, [string]$Path) {
    return $Path.Substring($Base.TrimEnd("\").Length + 1).Replace("\", "/")
}

function Join-Resource([string]$Base, [string]$Resource) {
    return Join-Path $Base ($Resource.Replace("/", "\"))
}

function New-ScratchDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("improved_hitmarker_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Export-Stock([string]$VpkPath, [string]$Output, [switch]$Decompile, [string]$Extensions) {
    $arguments = @("-i", $StockVpk, "--vpk_filepath", $VpkPath, "-o", $Output)
    if ($Decompile) {
        $arguments += "-d"
    }
    if ($Extensions) {
        $arguments += @("--vpk_extensions", $Extensions)
    }
    $result = Invoke-Native $S2v $arguments
    if ($result.ExitCode -ne 0) {
        throw "Source 2 Viewer could not export $VpkPath`n$($result.Output)"
    }
}

function Get-Blocks([byte[]]$Data) {
    $blockOffset = [BitConverter]::ToUInt32($Data, 8)
    $count = [BitConverter]::ToUInt32($Data, 12)
    $blocks = @()
    for ($index = 0; $index -lt $count; $index++) {
        $entry = 8 + $blockOffset + $index * 12
        $blocks += [pscustomobject]@{
            Name = [Text.Encoding]::ASCII.GetString($Data, $entry, 4)
            Entry = $entry
            Start = $entry + 4 + [BitConverter]::ToUInt32($Data, $entry + 4)
            Size = [BitConverter]::ToUInt32($Data, $entry + 8)
        }
    }
    return $blocks
}

function Get-Slice([byte[]]$Data, [int]$Start, [int]$Length) {
    $slice = New-Object byte[] $Length
    [Array]::Copy($Data, $Start, $slice, 0, $Length)
    return ,$slice
}

function Get-BlockBytes([byte[]]$Data, [string]$Name) {
    foreach ($block in (Get-Blocks $Data)) {
        if ($block.Name -eq $Name) {
            return ,(Get-Slice $Data $block.Start $block.Size)
        }
    }
    throw "resource has no $Name block"
}

function Set-Block([byte[]]$Template, [string]$Name, [byte[]]$Replacement) {
    $blocks = Get-Blocks $Template
    if (-not ($blocks | Where-Object { $_.Name -eq $Name })) {
        throw "template has no $Name block"
    }
    $firstStart = [int]($blocks | Measure-Object -Property Start -Minimum).Minimum
    $stream = New-Object IO.MemoryStream
    $stream.Write($Template, 0, $firstStart)
    $placements = @()
    foreach ($block in $blocks) {
        [byte[]]$content = $Replacement
        if ($block.Name -ne $Name) {
            $content = Get-Slice $Template $block.Start $block.Size
        }
        while ($stream.Length % $Alignment) {
            $stream.WriteByte(0)
        }
        $placements += [pscustomobject]@{ Entry = $block.Entry; Position = $stream.Length; Size = $content.Length }
        $stream.Write($content, 0, $content.Length)
    }
    $result = $stream.ToArray()
    foreach ($placement in $placements) {
        [Array]::Copy([BitConverter]::GetBytes([uint32]($placement.Position - ($placement.Entry + 4))), 0, $result, $placement.Entry + 4, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$placement.Size), 0, $result, $placement.Entry + 8, 4)
    }
    [Array]::Copy([BitConverter]::GetBytes([uint32]$result.Length), 0, $result, 0, 4)
    return ,$result
}

function Format-Kv3Value($Value) {
    if ($Value -is [bool]) {
        return $(if ($Value) { "true" } else { "false" })
    }
    if ($Value -is [string]) {
        return "`"$Value`""
    }
    $text = ([double]$Value).ToString("R", $Invariant)
    if ($text -notmatch "[.Ee]") {
        $text += ".0"
    }
    return $text
}

function Set-Field([string]$Body, [string]$Key, [string]$Value) {
    $line = "`t`t$Key = $Value`n"
    $field = [regex]::new('^\t\t' + [regex]::Escape($Key) + ' = (?:\n\t\t\[\n.*?^\t\t\]|[^\n]*)\n', "Multiline, Singleline")
    if (-not $field.IsMatch($Body)) {
        return $Body + $line
    }
    return $field.Replace($Body, [Text.RegularExpressions.MatchEvaluator]{ param($match) $line }, 1)
}

function Edit-Event([string]$Text, [string]$EventName, $Override) {
    $hasFiles = $null -ne $Override.PSObject.Properties["files"]
    $files = $Override.files
    $fields = Get-Pairs $Override.set
    $evaluator = [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($match.Groups[1].Value -ne $EventName) {
            return $match.Value
        }
        $body = $match.Groups[2].Value
        if ($hasFiles) {
            $lines = -join ($files | ForEach-Object { "`t`t`t`"$_`",`n" })
            $body = Set-Field $body "vsnd_files" "`n`t`t[`n$lines`t`t]"
        }
        foreach ($field in $fields) {
            $body = Set-Field $body $field.Name (Format-Kv3Value $field.Value)
        }
        return "`t$EventName = `n`t{`n$body`t}`n"
    }
    $updated = $EventPattern.Replace($Text, $evaluator)
    if ($updated -eq $Text -and -not $Text.Contains("`t$EventName = `n")) {
        throw "event $EventName not found"
    }
    return $updated
}

function Add-Event([string]$Text, [string]$EventName, $Definition) {
    if ($Text.Contains("`t$EventName = `n")) {
        throw "event $EventName already exists"
    }
    $body = "`t`tbase = `"$($Definition.base)`"`n"
    foreach ($field in (Get-Pairs $Definition.set)) {
        $body = Set-Field $body $field.Name (Format-Kv3Value $field.Value)
    }
    $lines = -join ($Definition.files | ForEach-Object { "`t`t`t`"$_`",`n" })
    $body = Set-Field $body "vsnd_files" "`n`t`t[`n$lines`t`t]"
    $end = $Text.LastIndexOf("}", [StringComparison]::Ordinal)
    return $Text.Substring(0, $end) + "`t$EventName = `n`t{`n$body`t}`n" + $Text.Substring($end)
}

function Get-SilencedEvents($Texts, [string[]]$Roots) {
    $bases = New-Object 'Collections.Generic.Dictionary[string,object]'
    foreach ($resource in $Texts.Keys) {
        foreach ($match in $EventPattern.Matches($Texts[$resource])) {
            $base = $BasePattern.Match($match.Groups[2].Value)
            $bases[$match.Groups[1].Value] = @($resource, $(if ($base.Success) { $base.Groups[1].Value } else { $null }))
        }
    }
    $found = New-Object 'Collections.Generic.Dictionary[string,object]'
    foreach ($name in $bases.Keys) {
        $current = $name
        $seen = New-Object 'Collections.Generic.HashSet[string]'
        $descends = $false
        while ($current -and -not $seen.Contains($current)) {
            if ($Roots -ccontains $current) {
                $descends = $true
                break
            }
            [void]$seen.Add($current)
            $current = if ($bases.ContainsKey($current)) { $bases[$current][1] } else { $null }
        }
        if ($descends) {
            $resource = $bases[$name][0]
            if (-not $found.ContainsKey($resource)) {
                $found[$resource] = [ordered]@{}
            }
            $found[$resource][$name] = [pscustomobject]@{ files = @($Silent) }
        }
    }
    return ,$found
}

function Get-EffectiveVolume($Bodies, [string]$Name) {
    $seen = New-Object 'Collections.Generic.HashSet[string]'
    while ($Name -and $Bodies.ContainsKey($Name) -and -not $seen.Contains($Name)) {
        [void]$seen.Add($Name)
        $volume = $VolumePattern.Match($Bodies[$Name])
        if ($volume.Success) {
            return [double]::Parse($volume.Groups[1].Value, $Invariant)
        }
        $base = $BasePattern.Match($Bodies[$Name])
        $Name = if ($base.Success) { $base.Groups[1].Value } else { $null }
    }
    return 0.0
}

function Add-Sounds($Sources) {
    $sounds = Read-ModJson "sounds.json"
    $encoding = Join-Path $ContentDir "sounds\encoding.txt"
    New-Item -ItemType Directory -Force -Path (Split-Path $encoding) | Out-Null
    Copy-Item -LiteralPath (Join-Path $Mod "sounds\encoding.txt") -Destination $encoding
    foreach ($pair in (Get-Pairs $sounds)) {
        $source = Join-Path $Mod $pair.Value
        if (-not (Test-Path -LiteralPath $source)) {
            throw "missing sound $source"
        }
        $destination = Join-Resource $ContentDir ($pair.Name + [IO.Path]::GetExtension($source))
        New-Item -ItemType Directory -Force -Path (Split-Path $destination) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
        $Sources[$destination] = $pair.Name + ".vsnd_c"
    }
}

function Add-SoundEvents($Sources, [string]$Scratch) {
    $config = Read-ModJson "soundevents.json"
    if ($null -eq $config) {
        return @()
    }
    $decompiled = Join-Path $Scratch "soundevents_decompiled"
    Export-Stock "soundevents/" $decompiled -Decompile -Extensions "vsndevts_c"
    $decompiled = (Get-Item -LiteralPath $decompiled).FullName
    $texts = New-Object 'Collections.Generic.Dictionary[string,string]'
    foreach ($file in (Get-ChildItem -LiteralPath $decompiled -Recurse -File | Where-Object { $_.Extension -eq ".vsndevts" })) {
        $texts[(Get-RelativePath $decompiled $file.FullName)] = Read-Text $file.FullName
    }
    if ($texts.Count -eq 0) {
        throw "could not decompile soundevents"
    }

    $overrides = Get-SilencedEvents $texts @($config.silence)
    $bodies = New-Object 'Collections.Generic.Dictionary[string,string]'
    foreach ($text in $texts.Values) {
        foreach ($match in $EventPattern.Matches($text)) {
            $bodies[$match.Groups[1].Value] = $match.Groups[2].Value
        }
    }
    $offset = if ($null -ne $config.volume_offset_db) { [double]$config.volume_offset_db } else { 0.0 }
    foreach ($resourcePair in (Get-Pairs $config.events)) {
        if (-not $overrides.ContainsKey($resourcePair.Name)) {
            $overrides[$resourcePair.Name] = [ordered]@{}
        }
        foreach ($eventPair in (Get-Pairs $resourcePair.Value)) {
            $override = $eventPair.Value
            if ($offset) {
                $fields = [ordered]@{}
                foreach ($field in (Get-Pairs $override.set)) {
                    $fields[$field.Name] = $field.Value
                }
                $fields["volume"] = [math]::Round((Get-EffectiveVolume $bodies $eventPair.Name) + $offset, 3)
                $replacement = [pscustomobject]@{ set = $fields }
                if ($null -ne $override.PSObject.Properties["files"]) {
                    $replacement | Add-Member -NotePropertyName files -NotePropertyValue $override.files
                }
                $override = $replacement
            }
            $overrides[$resourcePair.Name][$eventPair.Name] = $override
        }
    }

    $additions = [ordered]@{}
    foreach ($resourcePair in (Get-Pairs $config.add)) {
        $additions[$resourcePair.Name] = [ordered]@{}
        if (-not $overrides.ContainsKey($resourcePair.Name)) {
            $overrides[$resourcePair.Name] = [ordered]@{}
        }
        foreach ($eventPair in (Get-Pairs $resourcePair.Value)) {
            $definition = $eventPair.Value
            $fields = [ordered]@{}
            foreach ($field in (Get-Pairs $definition.set)) {
                $fields[$field.Name] = $field.Value
            }
            $volume = if ($fields.Contains("volume")) { [double]$fields["volume"] } else { Get-EffectiveVolume $bodies $definition.base }
            $fields["volume"] = [math]::Round($volume + $offset, 3)
            $additions[$resourcePair.Name][$eventPair.Name] = [pscustomobject]@{ base = $definition.base; files = $definition.files; set = $fields }
        }
    }

    $compiled = @()
    $eventCount = 0
    foreach ($resource in ($overrides.Keys | Sort-Object)) {
        if (-not $texts.ContainsKey($resource)) {
            throw "$resource not found in game soundevents"
        }
        $text = $texts[$resource]
        foreach ($eventPair in (Get-Pairs $overrides[$resource])) {
            $text = Edit-Event $text $eventPair.Name $eventPair.Value
            $eventCount++
        }
        if ($additions.Contains($resource)) {
            foreach ($eventPair in (Get-Pairs $additions[$resource])) {
                $text = Add-Event $text $eventPair.Name $eventPair.Value
                $eventCount++
            }
        }
        $destination = Join-Resource $ContentDir $resource
        Write-Text $destination $text
        $Sources[$destination] = $resource + "_c"
        $compiled += $resource + "_c"
    }
    Write-Host "overriding $eventCount events in $($overrides.Count) soundevent files"
    return $compiled
}

function Add-Panorama($Sources, [string]$Scratch) {
    $config = Read-ModJson "panorama.json"
    if ($null -eq $config) {
        return
    }
    foreach ($filePair in (Get-Pairs $config.files)) {
        $resource = $filePair.Name
        $output = Join-Path $Scratch ("panorama_" + [guid]::NewGuid().ToString("N"))
        Export-Stock ($resource + "_c") $output -Decompile
        $produced = @(Get-ChildItem -LiteralPath $output -Recurse -File)
        if ($produced.Count -ne 1) {
            throw "could not decompile $resource"
        }
        $text = Read-Text $produced[0].FullName
        foreach ($replace in @($filePair.Value.replace)) {
            if ($null -eq $replace) {
                continue
            }
            $index = $text.IndexOf($replace[0], [StringComparison]::Ordinal)
            if ($index -lt 0) {
                throw "'$($replace[0])' not found in $resource"
            }
            $text = $text.Substring(0, $index) + $replace[1] + $text.Substring($index + $replace[0].Length)
        }
        foreach ($append in @($filePair.Value.append)) {
            if ($null -ne $append) {
                $text += "`n" + (Read-Text (Join-Resource $Mod $append))
            }
        }
        $destination = Join-Resource $ContentDir $resource
        Write-Text $destination $text
        $Sources[$destination] = $resource + "_c"
    }
    foreach ($scriptPair in (Get-Pairs $config.scripts)) {
        $destination = Join-Resource $ContentDir ([IO.Path]::ChangeExtension($scriptPair.Name, ".js"))
        $script = Read-Text (Join-Resource $Mod $scriptPair.Value)
        if ($NoSound) {
            if (-not $script.Contains($AbilitySound)) {
                throw "'$AbilitySound' not found in $($scriptPair.Value)"
            }
            $script = $script.Replace($AbilitySound, 'const ABILITY_SOUND = "";')
        }
        Write-Text $destination $script
        $Sources[$destination] = $scriptPair.Name + "_c"
    }
}

function Invoke-Compile($Sources) {
    $fileList = Join-Path $ContentDir "filelist.txt"
    Write-Text $fileList ((@($Sources.Keys) -join "`n") + "`n")
    $result = Invoke-Native $Compiler @("-nop4", "-f", "-filelist", $fileList)
    Remove-Item -LiteralPath $fileList
    if ($result.ExitCode -ne 0 -or -not $result.Output.Contains(" 0 failed")) {
        throw $result.Output
    }
    foreach ($compiled in $Sources.Values) {
        if (-not (Test-Path -LiteralPath (Join-Resource $GameDir $compiled))) {
            throw "compiler did not produce $compiled"
        }
    }
}

function Restore-StockHeaders([string[]]$Resources, [string]$Scratch) {
    if ($Resources.Count -eq 0) {
        return
    }
    $raw = Join-Path $Scratch "soundevents_raw"
    Export-Stock "soundevents/" $raw -Extensions "vsndevts_c"
    foreach ($resource in $Resources) {
        $target = Join-Resource $GameDir $resource
        $template = [IO.File]::ReadAllBytes((Join-Resource $raw $resource))
        $data = Get-BlockBytes ([IO.File]::ReadAllBytes($target)) "DATA"
        [IO.File]::WriteAllBytes($target, (Set-Block $template "DATA" $data))
    }
}

foreach ($required in @($Compiler, $Packer, $S2v, $StockVpk)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "missing $required"
    }
}

foreach ($folder in @($ContentDir, $GameDir)) {
    foreach ($child in @("sounds", "soundevents", "panorama")) {
        Remove-Item -LiteralPath (Join-Path $folder $child) -Recurse -Force -ErrorAction SilentlyContinue
    }
}
New-Item -ItemType Directory -Force -Path $GameDir | Out-Null
$addonInfo = Join-Path $GameDir "addoninfo.txt"
if (-not (Test-Path -LiteralPath $addonInfo)) {
    Write-Text $addonInfo "`"AddonInfo`"`n{`n`t`"IsTemplate`"`t`"0`"`n`t`"IsPlayable`"`t`"0`"`n}`n"
}

$scratch = New-ScratchDirectory
try {
    $sources = [ordered]@{}
    $soundEvents = @()
    if (-not $NoSound) {
        Add-Sounds $sources
        $soundEvents = @(Add-SoundEvents $sources $scratch)
    }
    Add-Panorama $sources $scratch
    if ($sources.Count -eq 0) {
        throw "nothing to pack"
    }
    Invoke-Compile $sources
    Restore-StockHeaders $soundEvents $scratch
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path (Split-Path $DistVpk) | Out-Null
Remove-Item -LiteralPath $DistVpk -Force -ErrorAction SilentlyContinue
$pack = Invoke-Native $Packer @($GameDir, $DistVpk)
if ($pack.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $DistVpk)) {
    throw "VPK packer failed`n$($pack.Output)"
}
Write-Host "built $DistVpk"
foreach ($compiled in ($sources.Values | Sort-Object)) {
    Write-Host "  $compiled"
}

if ($Install) {
    & (Join-Path $PSScriptRoot "install.ps1") -Game $Game -Pak $Pak -NoSound:$NoSound
}
