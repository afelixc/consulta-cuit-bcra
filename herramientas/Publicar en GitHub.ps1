# Publica (o actualiza) Consulta CUIT BCRA en GitHub: afelixc/consulta-cuit-bcra
#  - CELULAR\  -> docs/  (GitHub Pages: https://afelixc.github.io/consulta-cuit-bcra/)
#  - PC\       -> PC/    + zip descargable en "Releases" (link fijo .../releases/latest/download/Consulta-CUIT-BCRA-PC.zip)
#  - README.md -> página de inicio del repositorio
# Solo sube los archivos que cambiaron. NUNCA sube HISTORIAL ni config.txt.
# Requiere GitHub CLI con sesión iniciada (gh auth login).
# Uso: doble clic en "PUBLICAR EN GITHUB.bat"  (o: .\Publicar en GitHub.ps1 -Mensaje "qué cambió")
param([string]$Mensaje = 'Actualización')

$ErrorActionPreference = 'Continue'   # gh escribe avisos en stderr; los errores se controlan con $LASTEXITCODE
$Repo = 'afelixc/consulta-cuit-bcra'
$Base = Split-Path -Parent $MyInvocation.MyCommand.Path
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = "$env:ProgramFiles\GitHub CLI\gh.exe" }
if (-not (Test-Path $gh)) { throw 'No está instalado GitHub CLI (winget install GitHub.cli) o falta iniciar sesión (gh auth login).' }

$ArchivosPC = 'ConsultaCUIT.ps1', 'cheque.ico', 'Consulta CUIT BCRA.bat', 'INSTALAR.bat', 'Instalar.ps1', 'LEEME.txt'
$ArchivosCel = 'index.html', 'manifest.webmanifest', 'sw.js', 'icono-192.png', 'icono-512.png', 'apple-touch-icon.png'

$tmp = Join-Path $env:TEMP 'publicar-consulta-cuit'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# --- Crear el repositorio si no existe ---
& $gh repo view $Repo --json name 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creando el repositorio $Repo..."
    & $gh repo create $Repo --public --description 'Consulta CUIT y cheques denunciados en el BCRA - app para celular y programa para PC'
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo crear el repositorio.' }
}

# SHA de git de un archivo (para saber si cambió sin bajarlo)
function Get-GitSha([byte[]]$bytes) {
    $cab = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $sha = [Security.Cryptography.SHA1]::Create()
    -join ($sha.ComputeHash([byte[]]($cab + $bytes)) | ForEach-Object { $_.ToString('x2') })
}

function Publish-Archivo([string]$rutaRepo, [string]$local) {
    $bytes = [IO.File]::ReadAllBytes($local)
    $url = "repos/$Repo/contents/" + (($rutaRepo -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
    $actual = & $gh api $url --jq '.sha' 2>$null
    if ($LASTEXITCODE -ne 0) { $actual = $null }
    if ($actual -and $actual.Trim() -eq (Get-GitSha $bytes)) { return $false }
    $cuerpo = @{ message = "$Mensaje ($rutaRepo)"; content = [Convert]::ToBase64String($bytes) }
    if ($actual) { $cuerpo.sha = $actual.Trim() }
    $json = Join-Path $tmp 'cuerpo.json'
    [IO.File]::WriteAllText($json, ($cuerpo | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    & $gh api -X PUT $url --input $json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudo subir $rutaRepo" }
    Write-Host "  subido: $rutaRepo"
    return $true
}

Write-Host 'Subiendo archivos...'
[void](Publish-Archivo 'README.md' (Join-Path $Base 'README.md'))
foreach ($a in $ArchivosCel) { [void](Publish-Archivo "docs/$a" (Join-Path $Base "CELULAR\$a")) }
$cambioPC = $false
foreach ($a in $ArchivosPC) { if (Publish-Archivo "PC/$a" (Join-Path $Base "PC\$a")) { $cambioPC = $true } }

# --- Página web (GitHub Pages desde /docs) ---
& $gh api "repos/$Repo/pages" --jq '.html_url' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Activando la página web...'
    & $gh api -X POST "repos/$Repo/pages" -f 'source[branch]=main' -f 'source[path]=/docs' | Out-Null
}

# --- Zip para descargar el programa de PC (solo si cambió algo de la PC o todavía no hay) ---
& $gh release view --repo $Repo 2>$null | Out-Null
if ($cambioPC -or $LASTEXITCODE -ne 0) {
    Write-Host 'Armando el zip del programa para PC...'
    $carpetaZip = Join-Path $tmp 'Consulta CUIT BCRA (PC)'
    Remove-Item $carpetaZip -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $carpetaZip | Out-Null
    foreach ($a in $ArchivosPC) { Copy-Item (Join-Path $Base "PC\$a") $carpetaZip }
    $zip = Join-Path $tmp 'Consulta-CUIT-BCRA-PC.zip'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path $carpetaZip -DestinationPath $zip
    $tag = 'pc-' + (Get-Date -Format 'yyyy.MM.dd-HHmm')
    & $gh release create $tag $zip --repo $Repo --title "Programa para PC ($(Get-Date -Format 'dd/MM/yyyy'))" --notes "$Mensaje`n`nDescargá Consulta-CUIT-BCRA-PC.zip, extraelo y hacé doble clic en INSTALAR.bat." --latest
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo crear el zip de descarga.' }
}

Write-Host ''
Write-Host 'LISTO.'
Write-Host '  Celular:  https://afelixc.github.io/consulta-cuit-bcra/'
Write-Host '  PC (zip): https://github.com/afelixc/consulta-cuit-bcra/releases/latest/download/Consulta-CUIT-BCRA-PC.zip'
Write-Host '  Página:   https://github.com/afelixc/consulta-cuit-bcra'
