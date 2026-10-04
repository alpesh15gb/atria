; Apex Books — Windows installer.
;
; Build the app first, then compile this file:
;
;     flutter build windows --release
;     "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\apex_books.iss
;
; Output: installer\output\Apex-Books-<version>-setup.exe
;
; Signing (optional, and required before this can ship to strangers):
;
;     ISCC.exe /DSign=True /DSignToolName=apexbooks installer\apex_books.iss
;
; with a code-signing tool registered once in the Inno IDE (Tools > Configure
; Sign Tools), or defined for CI on the ISCC command line. Registering the
; tool with Inno rather than shelling out afterwards is what lets it sign the
; uninstaller and the setup exe itself, which is the part SmartScreen actually
; looks at; a script that signs apex_books.exe only still shows the warning. Set
; SIGNTOOL_COMMAND (see installer/README.md) and pass the tool name in.

; Without /DSign=True nothing is signed and the build still works, so a
; developer without the certificate is not blocked.
;
; Source paths below are relative to this file, which is Inno's default for
; SourceDir, so no absolute paths are baked in.

#define MyAppName "Apex Books"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Apex Books"
#define MyAppExeName "apex_books.exe"
#define MyBundleDir "..\build\windows\x64\runner\Release"

; The version an update check compares against, so the number lives in one
; place: keep it in step with `version:` in pubspec.yaml.
#define MyAppVersionNumeric "1.0.0.0"

[Setup]
; Identifies the app across releases. Inno reads it from the uninstall entry to
; decide whether an install is an upgrade or a second copy, so changing it makes
; every existing install impossible to upgrade in place — the old one stays
; behind and the user ends up with two Atrias. Treat it as frozen.
AppId={{A37F4A6A-72EA-46AF-B0ED-632217310B22}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion={#MyAppVersion}
; Flutter's Windows runner targets Windows 10 and later.
MinVersion=10.0
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Per-user by default, so it installs without a UAC prompt on a shop PC where
; the person installing is not an administrator. With the dialog override an
; administrator can still choose an all-users install, and `{autopf}` then
; resolves to Program Files rather than %LOCALAPPDATA%\Programs.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=output
OutputBaseFilename=Apex-Books-{#MyAppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
#ifdef Sign
; The two directives that make an upgrade look legitimate to Windows. The
; uninstaller is a separate executable Inno generates at compile time, so it
; needs signing too — an unsigned unins000.exe under a signed installer is one
; of the things SmartScreen flags.
SignTool={#SignToolName}
SignedUninstaller=yes
#endif
; Let the Restart Manager close a running copy, so upgrading while Apex Books is
; open does not fail half-way with "file in use".
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked
Name: "startmenuicon"; Description: "Create a Start Menu shortcut"; GroupDescription: "Shortcuts:"

[Files]
; The whole release bundle: apex_books.exe, flutter_windows.dll, the plugin DLLs,
; the bundled MSVC runtime, and data\ (the AOT payload and assets).
Source: "{#MyBundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; Shortcuts land directly in Start Menu > Programs. Adding an {group} entry as
; well would create a folder *and* a loose shortcut with the same name, which
; reads as a duplicate rather than as two ways to the same app.
[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: startmenuicon
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

; Deliberately no [UninstallDelete] for data. The books live in the user's own
; profile — the drift database under the app support directory and JSON backups
; under Documents\apexbooks\backups — not under {app}. Uninstalling the program must
; never be the thing that deletes someone's accounting records.
