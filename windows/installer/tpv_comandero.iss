; Instalador de Windows de TPV Comandero (Inno Setup 6).
;
; Lo compila tool/empaquetar.ps1, que le pasa por /D:
;   AppVersion   versión de pubspec.yaml sin el número de compilación (p. ej. 1.0.0)
;   SourceDir    salida de `flutter build windows --release` (build\windows\x64\runner\Release)
;   VcRuntimeDir carpeta con msvcp140*.dll y vcruntime140*.dll (Redist de Visual Studio)
;   OutputDir    carpeta de salida (dist)
;
; Datos del usuario: el instalador NO los toca y el desinstalador NO los borra. Viven en
; %APPDATA%\TPV Comandero\TPV Comandero (diario del host, caché y shared_preferences.json)
; y en el Administrador de credenciales de Windows (secretos). Ver INSTALACION.md.

#ifndef AppVersion
  #error Falta /DAppVersion=x.y.z
#endif
#ifndef SourceDir
  #error Falta /DSourceDir=<build\windows\x64\runner\Release>
#endif
#ifndef VcRuntimeDir
  #error Falta /DVcRuntimeDir=<carpeta Microsoft.VC14x.CRT x64>
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

#define AppName "TPV Comandero"
#define AppExe "tpv_comandero.exe"
#define ReglaTcp "TPV Comandero - comandas (TCP 4040)"
#define ReglaUdp "TPV Comandero - descubrimiento (UDP 4041)"

[Setup]
; AppId identifica la instalación para actualizar encima y desinstalar: no cambiarlo nunca.
AppId={{FBA4192A-831A-4FCF-922E-B96B47E481CB}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppName}
AppCopyright=Copyright (C) 2026 {#AppName}
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription=Instalador de {#AppName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=TPV-Comandero-Setup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName} {#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Cierra la app si está abierta al actualizar o desinstalar.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
; Runtime de Visual C++ junto al ejecutable (despliegue local): la app arranca aunque el
; equipo no tenga instalado el redistribuible.
Source: "{#VcRuntimeDir}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRuntimeDir}\msvcp140_1.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRuntimeDir}\msvcp140_2.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRuntimeDir}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRuntimeDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; Cortafuegos: el host recibe comandas por TCP 4040 y sondeos de descubrimiento por UDP 4041.
; Se borran antes por si se instala encima de una versión anterior (sin duplicar reglas).
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#ReglaTcp}"""; Flags: runhidden waituntilterminated; StatusMsg: "Configurando el cortafuegos de Windows..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#ReglaUdp}"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#ReglaTcp}"" dir=in action=allow program=""{app}\{#AppExe}"" protocol=TCP localport=4040 profile=private,domain enable=yes"; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#ReglaUdp}"" dir=in action=allow program=""{app}\{#AppExe}"" protocol=UDP localport=4041 profile=private,domain enable=yes"; Flags: runhidden waituntilterminated
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#ReglaTcp}"""; Flags: runhidden waituntilterminated; RunOnceId: "BorrarReglaTcp"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#ReglaUdp}"""; Flags: runhidden waituntilterminated; RunOnceId: "BorrarReglaUdp"

; Sin [UninstallDelete]: el desinstalador solo quita lo que instaló y conserva los datos
; del usuario (diario del host, ajustes y secretos) por si se reinstala o se actualiza.
