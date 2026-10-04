# Windows installer

Two artifacts, both built from the same release bundle:

| Artifact | What it is |
| --- | --- |
| `output/Atria-1.0.0-setup.exe` | The installer. Per-user by default (no UAC prompt), with a dialog option for an all-users install. Registers in **Apps & features** as `Atria 1.0.0`, and uninstalls cleanly. |
| `output/Atria-1.0.0-windows-x64-portable.zip` | The same files zipped, for a machine where nothing may be installed. Unzip and run `atria.exe`. |

## Build

```bash
flutter build windows --release
"C:\InnoSetup6\ISCC.exe" installer/atria.iss
```

The portable zip is the same bundle zipped by hand — Inno does not produce it:

```bash
powershell -NoProfile -Command "Compress-Archive -Path 'build\windows\x64\runner\Release\*' -DestinationPath 'installer\output\Atria-1.0.0-windows-x64-portable.zip' -Force"
```

Inno Setup 6 is installed at `C:\InnoSetup6\` on this machine (not the usual
`Program Files (x86)` path, and `ISCC.exe` is not on `PATH`). `installer/atria.iss`
reads from `build\windows\x64\runner\Release\*`, so the Flutter build must run first —
the script does not build the app itself.

## Things that must not change casually

- **`AppId` in `atria.iss`.** Inno uses it to tell an upgrade from a second copy. Change
  it and every existing install becomes un-upgradable — the user is left with two Atrias.
- **`MyAppVersion`.** Keep it in step with `version:` in `pubspec.yaml`; the setup exe's
  version resource and the Apps & features entry both come from here.
- **The MSVC runtime** in `windows/CMakeLists.txt`. It is bundled app-locally on purpose:
  without it, a machine that has never had the Visual C++ 2015-2022 redistributable fails
  in the loader, before any app code runs, with no window and no error.

## Code signing

`atria.iss` has the hooks; they are off unless you pass `/DSign=True`:

```bash
ISCC.exe /DSign=True /DSignToolName=atria installer/atria.iss
```

Registering the sign tool **with Inno** (`Tools > Configure Sign Tools` in the IDE, or
`/S<name>=<command>` to `ISCC`) is the point: Inno then signs `unins000.exe`
(`SignedUninstaller=yes`) and the setup exe itself. Signing `atria.exe` yourself
before packaging is *not* a substitute — the file Windows shows the SmartScreen
warning about is the setup exe the user just downloaded.

A typical command, with the certificate in a `.pfx` and a timestamp server so the
signature outlives the certificate:

```
signtool sign /f C:\keys\atria.pfx /p $p /fd sha256 /tr http://timestamp.digicert.com /td sha256 $f
```

Without a certificate the build still succeeds and the installer is unsigned; that is
deliberate, so a developer is never blocked. An unsigned build must not be handed to a
shop — SmartScreen will show "unrecognised app" and the shop has no way to tell that
apart from malware.

## Auto-update

Not built. What an updater needs is already fixed in place, which is the scaffolding:

- **A stable identity.** `AppId` never changes, so a newer setup exe is an *upgrade* of
  the existing install rather than a second copy. An updater can therefore just run the
  downloaded setup exe.
- **A per-user default install** (`PrivilegesRequired=lowest`), so the upgrade needs no
  UAC prompt — an updater that raises a UAC prompt on every release is one shops switch
  off.
- **`CloseApplications=yes`**, so upgrading while Atria is open does not fail with
  "file in use".
- **A predictable file name** — `Atria-<version>-setup.exe` — which is what a manifest of
  releases points at.

The missing pieces are a release endpoint (a `latest.json` with `version`, `url` and a
SHA-256 the app verifies before running anything) and the in-app prompt. Until the setup
is signed, an auto-updater would have to be turned off anyway: silently downloading an
unsigned executable is exactly the behaviour of the thing users are warned about.

## Limits worth knowing

- **x64 only.** `ArchitecturesAllowed=x64compatible` — an ARM64 Windows device would need
  a separate `flutter build windows --release --target-platform windows-arm64` bundle.
- **Uninstalling never deletes books.** The drift database and JSON backups live in the
  user's own profile (`AppData` and `Documents\atria\backups`), not under `{app}`, and the
  script deliberately has no `[UninstallDelete]` rule for them.
- **The Android APK is signed from `android/key.properties`** when that file exists, and
  with the debug key when it does not. Only the release-signed APK may be distributed;
  the Gradle build prints a warning when it falls back.

## Verified

A silent install into a throwaway directory, then a silent uninstall:

```powershell
Start-Process -Wait "installer\output\Atria-1.0.0-setup.exe" `
  -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/DIR=D:\tmp\atria-test'
Start-Process -Wait 'D:\tmp\atria-test\unins000.exe' `
  -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART'
```

Use PowerShell for this, not Git Bash. Git Bash rewrites any argument starting with `/`
into a path (`/VERYSILENT` arrives as a drive path) and eats unquoted backslashes, so
`/DIR=D:\tmp\atria-test` reaches the installer as the *relative* `D:tmp\atria-test` — which
silently installs into the current directory instead of `D:\tmp`, and the test passes for
the wrong reason. `MSYS2_ARG_CONV_EXCL='*'` only fixes the first half.

The first left the full bundle (including `data\app.so` and the eight runtime DLLs) and an
`HKCU\...\Uninstall\{A37F4A6A-72EA-46AF-B0ED-632217310B22}_is1` entry showing
`DisplayName=Atria`, `DisplayVersion=1.0.0`, `Publisher=com.atria`. The second removed both
the directory and the registry entry.
