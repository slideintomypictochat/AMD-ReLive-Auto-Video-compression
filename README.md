# ReLive Compressor

Shrinks AMD Radeon ReLive recordings to a fraction of their size with almost no visible difference. It re-encodes them on the graphics card (AV1 on RX 7000 and newer, HEVC on RX 400 – RX 6000) and keeps 1440p/60 fps and the original audio.

- Runs from the tray. Compresses automatically while you're away from the PC and pauses the moment you're back.
- The **Compress** page lets you tick exactly which recordings to compress now. You can also right-click videos in File Explorer, or drop them on the window.
- Originals are only touched after the compressed copy has been checked. You choose **Test** (keep originals), **Replace** (optionally via the Recycle Bin) or **Move**.
- A before/after viewer, plain-language error messages and a welcome guide.
- Updates itself from this repository's releases.

## Install

Download `ReLiveCompressorSetup.exe` from the [latest release](https://github.com/slideintomypictochat/AMD-ReLive-Auto-Video-compression/releases/latest) and run it. No admin rights are needed. It installs for the current user only and can be removed from Settings > Apps.

Windows may warn that the installer isn't signed. Choose **More info > Run anyway**.

## Layout

| Folder | What's in it |
|---|---|
| `ReLive Compressor/` | the app: tray app (`ReLiveCompressor.ps1`), window (`MainWindow.xaml`/`.ps1`), `Worker.ps1` (ffmpeg), install/uninstall scripts |
| `Build/` | `Setup.cs` (installer), `AppHost.cs` (`ReLiveCompressor.exe`), build and publish scripts |

`Build/ffmpeg/ffmpeg.exe` isn't in the repository because of its size. Put a GPL build of ffmpeg 7.x with `av1_amf`/`hevc_amf` there (e.g. from [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds)).

## Building and publishing an update

```powershell
# installer only -> dist\ReLive Compressor Setup.exe
powershell -ExecutionPolicy Bypass -File Build\Build-Setup.ps1

# new version for everyone who has it installed (needs GitHub CLI: winget install GitHub.cli, then gh auth login)
powershell -ExecutionPolicy Bypass -File Build\Publish-Update.ps1 -Version 1.6.1 -Notes "Fixed X", "Added Y"
```

`Publish-Update.ps1` does three things:

1. Stamps the version everywhere.
2. Builds the installer.
3. Creates a GitHub release that carries `ReLiveCompressorSetup.exe` and `update.json` (version, size, SHA-256).

Installed copies check `releases/latest/download/update.json` once a day. When there's a newer version, they show **Update available**. They refuse any download that doesn't match the published size and hash.

## Licence

Free to use and share, provided as is (see `ReLive Compressor/License.txt`). The installer bundles FFmpeg, which is licensed under the GPL v3. See `ThirdPartyNotices.txt` and `FFmpeg-GPLv3.txt`. The FFmpeg source code is available at <https://ffmpeg.org/download.html> and <https://github.com/BtbN/FFmpeg-Builds>.
