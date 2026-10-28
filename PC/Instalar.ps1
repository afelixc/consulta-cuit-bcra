# Instalador de "Consulta CUIT BCRA" para otra PC.
# Copia el programa a %LOCALAPPDATA%\Programs\Consulta CUIT BCRA y crea el acceso directo en el Escritorio.
# Uso: doble clic en "INSTALAR.bat" (o: Instalar.ps1 -SinPreguntas)
param([switch]$SinPreguntas, [string]$Destino = (Join-Path $env:LOCALAPPDATA 'Programs\Consulta CUIT BCRA'), [string]$Escritorio = [Environment]::GetFolderPath('Desktop'))

Add-Type -AssemblyName System.Windows.Forms

$Origen  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Archivos = 'ConsultaCUIT.ps1', 'cheque.ico', 'Consulta CUIT BCRA.bat'

try {
    New-Item -ItemType Directory -Path $Destino -Force | Out-Null
    foreach ($a in $Archivos) {
        Copy-Item (Join-Path $Origen $a) (Join-Path $Destino $a) -Force -ErrorAction Stop
        # Si vino bajado de internet (zip de GitHub), Windows lo marca como "bloqueado": se desbloquea
        Unblock-File -LiteralPath (Join-Path $Destino $a) -ErrorAction SilentlyContinue
    }

    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path $Escritorio 'Consulta CUIT BCRA.lnk'))
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Destino\ConsultaCUIT.ps1`""
    $lnk.WorkingDirectory = $Destino
    $lnk.IconLocation = "$Destino\cheque.ico,0"
    $lnk.WindowStyle = 7
    $lnk.Save()
    try { ie4uinit.exe -show } catch { }

    $msg = "Listo. Quedó instalado en esta PC ($env:COMPUTERNAME).`n`nEn el Escritorio tenés el ícono 'Consulta CUIT BCRA'.`n`nLa primera vez que lo abras te pregunta dónde guardar el historial (Google Drive o solo esta PC)."
    if (-not $SinPreguntas) { [Windows.Forms.MessageBox]::Show($msg, 'Consulta CUIT BCRA', 'OK', 'Information') | Out-Null } else { $msg }
} catch {
    $msg = "No se pudo instalar: $($_.Exception.Message)"
    if (-not $SinPreguntas) { [Windows.Forms.MessageBox]::Show($msg, 'Consulta CUIT BCRA', 'OK', 'Error') | Out-Null } else { throw $msg }
}
