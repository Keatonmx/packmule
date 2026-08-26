# Packmule

A free file mule for iOS, by Redfern's Outpost. It hauls files between your
phone and anything that speaks **SMB** or **FTP**: a Windows share like
`\\10.0.0.253\media`, a NAS, a Raspberry Pi, another phone running an FTP
server.

**Free means free.** SMB, FTP, uploads, downloads: all of it. There is no Pro
tier, no subscription, no unlock. A file app should not ransom your own files
back to you.

## What it does

- **SMB2/3 shares** — connect straight to `smb://10.0.0.253/media`. Leave the
  share field empty and Packmule lists the server's shares to pick from.
  Pasting a Windows path (`\\10.0.0.253\media`) into the Host field just works.
- **FTP** — a from-scratch client on Apple's Network framework (passive mode,
  MLSD with LIST fallback). Anonymous or signed in.
- **VPN friendly** — on WireGuard or Tailscale, use the tunnel address and go.
  Packmule doesn't care how the packets get there.
- **Nearby** — Bonjour discovery lists SMB/FTP servers advertising on the LAN.
- **Files app** — downloads land in `On My iPhone › Packmule › Downloads`.
  Imports come in through the system file picker.
- **The usual moves** — download, upload, preview (Quick Look), share, rename,
  new folder, delete, with a live transfer queue.
- Passwords live in the iOS Keychain. No accounts, ads or analytics.

## Building

There is no Mac in this workflow. Every push to `main` runs
`.github/workflows/build.yml` on a GitHub macOS runner, which:

1. builds for the iOS Simulator and captures demo-mode screenshots,
2. builds an **unsigned device IPA**,
3. uploads both as artifacts and publishes the IPA to the rolling
   [`latest` release](../../releases/latest).

Install by signing the IPA with [Sideloadly](https://sideloadly.io) (a free
Apple ID gives a 7-day signature).

After adding or removing source files, regenerate the Xcode project:

```
python3 Scripts/gen_xcodeproj.py
```

The app icon is rendered by `python3 Scripts/gen_icon.py` (stdlib only).

### Debug launch arguments (used by CI screenshots)

- `-packmule-demo` — seeded servers and nearby devices, nothing persisted
- `-packmule-browse` — open a fake media-share listing
- `-packmule-transfers` — seed the transfer queue
- `-packmule-sheet addServer|serverActions|fileActions|transfers|settings|about|newFolder`
- `-packmule-theme Mule|Modern|Tin|Midnight|Forest|Ember|Mint|Grape|Sakura`

## Credits

- [AMSMB2](https://github.com/amosavian/AMSMB2) (MIT) and
  [libsmb2](https://github.com/sahlberg/libsmb2) (LGPL-2.1) for SMB.
- The FTP engine is Packmule's own.

Packmule's source is MIT licensed.
