$RepoRoot = Split-Path $PSScriptRoot -Parent
$ModName = "improved_hitmarker"

function Get-DistVpk([bool]$NoSound) {
    $suffix = if ($NoSound) { "_no_sound" } else { "" }
    return Join-Path $RepoRoot "dist\$ModName$suffix.vpk"
}

function Get-DotEnv {
    $values = @{}
    $path = Join-Path $RepoRoot ".env"
    if (-not (Test-Path -LiteralPath $path)) {
        return $values
    }
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $match = [regex]::Match($line, '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$')
        if (-not $match.Success) {
            continue
        }
        $value = $match.Groups[2].Value
        if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") {
            $value = $matches[1]
        } else {
            $value = ($value -replace '\s+#.*$', '')
        }
        $values[$match.Groups[1].Value] = $value
    }
    return $values
}

function Get-ConfigValue([string]$Name) {
    $value = (Get-DotEnv)[$Name]
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name)
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }
    return [Environment]::ExpandEnvironmentVariables($value)
}

function Get-SteamLibraries {
    $steamRoots = @()
    foreach ($key in @("HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam")) {
        try {
            $steamRoots += Get-ItemPropertyValue -Path $key -Name "InstallPath" -ErrorAction Stop
        } catch {
        }
    }
    try {
        $steamRoots += (Get-ItemPropertyValue -Path "HKCU:\Software\Valve\Steam" -Name "SteamPath" -ErrorAction Stop).Replace("/", "\")
    } catch {
    }
    $steamRoots += "C:\Program Files (x86)\Steam"

    $libraries = @()
    foreach ($root in ($steamRoots | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        $libraries += $root
        $folders = Join-Path $root "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $folders) {
            foreach ($match in [regex]::Matches([IO.File]::ReadAllText($folders), '"path"\s+"([^"]+)"')) {
                $libraries += $match.Groups[1].Value.Replace("\\", "\")
            }
        }
    }
    return $libraries | Sort-Object -Unique
}

function Test-DeadlockRoot([string]$Path) {
    return $Path -and (Test-Path -LiteralPath (Join-Path $Path "game\citadel\gameinfo.gi"))
}

function Resolve-DeadlockRoot([string]$Explicit) {
    foreach ($candidate in @($Explicit, (Get-ConfigValue "DEADLOCK_PATH"))) {
        if ($candidate) {
            if (-not (Test-DeadlockRoot $candidate)) {
                throw "Deadlock not found at '$candidate' (expected game\citadel\gameinfo.gi)"
            }
            return $candidate
        }
    }
    foreach ($library in (Get-SteamLibraries)) {
        $candidate = Join-Path $library "steamapps\common\Deadlock"
        if (Test-DeadlockRoot $candidate) {
            return $candidate
        }
    }
    throw "could not find Deadlock in any Steam library; set DEADLOCK_PATH in .env or pass -Game"
}

function Resolve-CsdkRoot([string]$Explicit) {
    $configured = @($Explicit, (Get-ConfigValue "CSDK_PATH")) | Where-Object { $_ }
    $candidates = if ($configured) { @($configured)[0] } else { "C:\Reduced_CSDK_12" }
    foreach ($candidate in @($candidates, (Join-Path $candidates "Reduced_CSDK_12"))) {
        if (Test-Path -LiteralPath (Join-Path $candidate "game\bin_cs2\win64\resourcecompiler.exe")) {
            return $candidate
        }
    }
    throw "CSDK 12 not found at '$candidates'; set CSDK_PATH in .env or pass -Csdk"
}

function Resolve-Source2Viewer([string]$Explicit) {
    $configured = @($Explicit, (Get-ConfigValue "S2V_PATH")) | Where-Object { $_ }
    if ($configured) {
        $candidate = @($configured)[0]
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $candidate = Join-Path $candidate "Source2Viewer-CLI.exe"
        }
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw "Source2Viewer-CLI not found at '$candidate'"
        }
        return $candidate
    }
    $command = Get-Command "Source2Viewer-CLI.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    throw "Source2Viewer-CLI not found; set S2V_PATH in .env, add it to PATH, or pass -S2v"
}
