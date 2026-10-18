<#
.SYNOPSIS
  Empaqueta TPV Comandero para instalarlo en un cliente.

.DESCRIPTION
  Ejecuta, en orden y parando al primer fallo:
    1. flutter pub get, flutter analyze y flutter test (suite normal);
    2. flutter build apk --release (APK universal firmado con android/key.properties);
    3. flutter build windows --release;
    4. el instalador de Windows con Inno Setup (windows/installer/tpv_comandero.iss);
    5. el zip del plugin de FacturaScripts (carpeta Hosteleria/ en la raíz del zip);
  y deja en dist/ los artefactos con nombre versionado y SHA256SUMS.txt:
    TPV-Comandero-Setup-<versión>.exe, tpv-comandero-<versión>.apk, Hosteleria-<versión plugin>.zip

  Requisitos: Flutter en el PATH, Android SDK, Visual Studio (C++ de escritorio),
  Inno Setup 6 y android/key.properties con la clave de publicación (ver INSTALACION.md).

.PARAMETER OmitirPruebas
  No ejecuta flutter analyze ni flutter test (solo para repetir un empaquetado ya probado).

.PARAMETER Iscc
  Ruta de ISCC.exe si Inno Setup no está en una ubicación estándar.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool\empaquetar.ps1
#>
[CmdletBinding()]
param(
    [switch]$OmitirPruebas,
    [string]$Iscc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $raiz 'dist'

function Paso([string]$texto) {
    Write-Host ''
    Write-Host "==> $texto" -ForegroundColor Cyan
}

# Ejecuta un programa externo y para el script si termina con error.
function Ejecutar([string]$programa, [string[]]$argumentos) {
    & $programa @argumentos
    if ($LASTEXITCODE -ne 0) {
        throw "Falló '$programa $($argumentos -join ' ')' (código $LASTEXITCODE)."
    }
}

function Leer-VersionApp {
    $linea = Select-String -Path (Join-Path $raiz 'pubspec.yaml') -Pattern '^version:\s*(\S+)' |
        Select-Object -First 1
    if (-not $linea) { throw 'No se encuentra "version:" en pubspec.yaml.' }
    $completa = $linea.Matches[0].Groups[1].Value
    if ($completa -notmatch '^(\d+\.\d+\.\d+)(\+\d+)?$') {
        throw "Versión de pubspec.yaml no reconocida: $completa"
    }
    return $Matches[1]
}

function Leer-VersionPlugin([string]$ini) {
    $linea = Select-String -Path $ini -Pattern "^\s*version\s*=\s*'?([0-9.]+)'?" |
        Select-Object -First 1
    if (-not $linea) { throw "No se encuentra la versión en $ini." }
    return $linea.Matches[0].Groups[1].Value
}

function Buscar-Iscc {
    if ($Iscc) {
        if (-not (Test-Path $Iscc)) { throw "No existe ISCC.exe en '$Iscc'." }
        return $Iscc
    }
    $comando = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($comando) { return $comando.Source }
    $candidatos = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    foreach ($ruta in $candidatos) {
        if (Test-Path $ruta) { return $ruta }
    }
    throw ('No se encuentra Inno Setup 6 (ISCC.exe). Instálalo con: winget install ' +
        '--id JRSoftware.InnoSetup -e   o indica la ruta con -Iscc.')
}

# Carpeta x64 con las DLL redistribuibles del runtime de Visual C++ (Microsoft.VC14x.CRT).
function Buscar-RuntimeVc {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw 'No se encuentra vswhere.exe (Visual Studio).' }
    $instalaciones = & $vswhere -all -products * -property installationPath
    foreach ($vs in $instalaciones) {
        $redist = Join-Path $vs 'VC\Redist\MSVC'
        if (-not (Test-Path $redist)) { continue }
        $crt = Get-ChildItem $redist -Directory |
            Where-Object { $_.Name -match '^\d+\.' } |
            Sort-Object { [version]$_.Name } -Descending |
            ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue } |
            Where-Object { Test-Path (Join-Path $_.FullName 'vcruntime140_1.dll') } |
            Select-Object -First 1
        if ($crt) { return $crt.FullName }
    }
    throw 'No se encuentran las DLL redistribuibles de Visual C++ (VC\Redist\MSVC\<versión>\x64\Microsoft.VC*.CRT).'
}

# Zip del plugin con la carpeta del plugin en la raíz y separadores "/" (Compress-Archive
# de Windows PowerShell 5.1 escribe "\" y FacturaScripts en Linux no lo descomprimiría bien).
# Solo entran los ficheros versionados o no ignorados por git: nada de restos locales.
function Crear-ZipPlugin([string]$carpetaPlugin, [string]$destino) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $nombre = Split-Path -Leaf $carpetaPlugin
    $relativa = (Resolve-Path -Relative $carpetaPlugin) -replace '^\.\\', '' -replace '\\', '/'
    Push-Location $raiz
    try {
        $ficheros = & git ls-files --cached --others --exclude-standard -- $relativa
        if ($LASTEXITCODE -ne 0) { throw 'git ls-files falló al listar el plugin.' }
    } finally {
        Pop-Location
    }
    $ficheros = @($ficheros | Where-Object { $_ -and (Test-Path (Join-Path $raiz $_)) })
    if (-not ($ficheros -contains "$relativa/facturascripts.ini")) {
        throw "El plugin no tiene facturascripts.ini en $relativa."
    }
    if (Test-Path $destino) { Remove-Item $destino -Force }
    $zip = [System.IO.Compression.ZipFile]::Open($destino, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($fichero in $ficheros) {
            $entrada = $nombre + '/' + $fichero.Substring($relativa.Length + 1)
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, (Join-Path $raiz $fichero), $entrada,
                [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }
    return $ficheros.Count
}

Push-Location $raiz
try {
    $version = Leer-VersionApp
    $iniPlugin = Join-Path $raiz 'erp\Hosteleria\facturascripts.ini'
    $versionPlugin = Leer-VersionPlugin $iniPlugin
    Write-Host "TPV Comandero $version · plugin Hosteleria $versionPlugin"

    # Comprobaciones previas: mejor fallar ahora que tras diez minutos de compilación.
    $isccExe = Buscar-Iscc
    $runtimeVc = Buscar-RuntimeVc
    if (-not (Test-Path (Join-Path $raiz 'android\key.properties'))) {
        throw 'Falta android\key.properties con la clave de publicación (ver INSTALACION.md).'
    }

    New-Item -ItemType Directory -Force $dist | Out-Null
    $apkDist = Join-Path $dist "tpv-comandero-$version.apk"
    $setupDist = Join-Path $dist "TPV-Comandero-Setup-$version.exe"
    $zipDist = Join-Path $dist "Hosteleria-$versionPlugin.zip"
    $sumas = Join-Path $dist 'SHA256SUMS.txt'
    foreach ($viejo in @($apkDist, $setupDist, $zipDist, $sumas)) {
        if (Test-Path $viejo) { Remove-Item $viejo -Force }
    }

    Paso 'flutter pub get'
    Ejecutar 'flutter' @('pub', 'get')

    if ($OmitirPruebas) {
        Write-Host 'Se omiten flutter analyze y flutter test (-OmitirPruebas).' -ForegroundColor Yellow
    } else {
        Paso 'flutter analyze'
        Ejecutar 'flutter' @('analyze')
        Paso 'flutter test'
        Ejecutar 'flutter' @('test', '--timeout', '60s')
    }

    Paso 'flutter build apk --release'
    Ejecutar 'flutter' @('build', 'apk', '--release')
    $apk = Join-Path $raiz 'build\app\outputs\flutter-apk\app-release.apk'
    if (-not (Test-Path $apk)) { throw "No se ha generado $apk." }
    Copy-Item $apk $apkDist

    Paso 'flutter build windows --release'
    Ejecutar 'flutter' @('build', 'windows', '--release')
    $release = Join-Path $raiz 'build\windows\x64\runner\Release'
    if (-not (Test-Path (Join-Path $release 'tpv_comandero.exe'))) {
        throw "No se ha generado tpv_comandero.exe en $release."
    }

    Paso 'Instalador de Windows (Inno Setup)'
    Ejecutar $isccExe @(
        '/Q',
        "/DAppVersion=$version",
        "/DSourceDir=$release",
        "/DVcRuntimeDir=$runtimeVc",
        "/DOutputDir=$dist",
        (Join-Path $raiz 'windows\installer\tpv_comandero.iss')
    )
    if (-not (Test-Path $setupDist)) { throw "No se ha generado $setupDist." }

    Paso 'Zip del plugin de FacturaScripts'
    $n = Crear-ZipPlugin (Join-Path $raiz 'erp\Hosteleria') $zipDist
    Write-Host "$n ficheros en $(Split-Path -Leaf $zipDist)"

    Paso 'Sumas SHA-256'
    $lineas = foreach ($artefacto in @($setupDist, $apkDist, $zipDist)) {
        $hash = (Get-FileHash -Algorithm SHA256 $artefacto).Hash.ToLowerInvariant()
        "$hash *$(Split-Path -Leaf $artefacto)"
    }
    [System.IO.File]::WriteAllLines($sumas, [string[]]$lineas)

    Paso "Listo: artefactos en $dist"
    Get-ChildItem $dist -File | ForEach-Object {
        '{0,-36} {1,10:N0} KB' -f $_.Name, ($_.Length / 1KB)
    }
    Get-Content $sumas
} finally {
    Pop-Location
}
