# Deadlock Improved Hitmarker

Deadlock mod that replaces the hitmarker visuals and sounds.

- New custom-made hit & headshot sounds
- New Overwatch-inspired hitmarker (with red color for crits)
- Show hitmarkers when hitting skills as well

## Installing

Download it from GameBanana: https://gamebanana.com/mods/728587

Or build and install manually.

## Building

Requires [CSDK 12](https://deadlockmodding.pages.dev/modding-tools/csdk-12) and [Source 2 Viewer CLI](https://valveresourceformat.github.io/).

Copy `.env.example` as `.env` and edit it accordingly:

```powershell
cp .env.example .env
```

Run this command to build the mod:

```powershell
.\scripts\build.ps1
# or just the hitmarker, without custom sounds:
.\scripts\build.ps1 -NoSound
```

With Deadlock closed, install the mod in your game path by running:

```powershell
.\scripts\install.ps1
# or:
.\scripts\build.ps1 -NoSound
```
