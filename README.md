# Deadlock Improved Hitmarker

Deadlock mod that replaces the hitmarker visuals and sounds.

- Custom hit and headshot sounds
- Custom hitmarker inspired by Overwatch, including red color for crits

## Installing

GameBanana: (botar link aqui)

Deadlock Mod Manager: (botar link aqui)

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
```

With Deadlock closed, install the mod in your game path by running:

```powershell
.\scripts\install.ps1
```
