# Consulta CUIT - BCRA (Central de Deudores + Cheques denunciados)
# Usa la API oficial y gratuita del BCRA (api.bcra.gob.ar), sin captcha.
# v1.1 - 2026-10-28: solapas (Informe por CUIT / Cheques denunciados) y botón PDF
# v1.2 - 2026-10-28: carteles de ayuda en cada casillero, tilde "Guardar" con nota + ventana Guardados,
#                    banco buscable por nombre o por código
# v1.3 - 2026-10-28: colores por solapa; historial en Google Drive compartido entre PCs (pregunta la primera vez)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()   # necesario para los textos de ayuda dentro de los casilleros
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -Namespace Win32 -Name Cue -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int msg, System.IntPtr wParam, string lParam);
'@
Add-Type -Namespace Win32 -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
'@

# Colores de cada solapa: Oscuro = solapa elegida y barra de título, Medio = solapa sin elegir, Claro = fondo
$Colores = @{
    CUIT   = @{ Oscuro = [Drawing.Color]::FromArgb(31, 78, 140); Medio = [Drawing.Color]::FromArgb(205, 222, 243); Claro = [Drawing.Color]::FromArgb(236, 243, 251) }
    Cheque = @{ Oscuro = [Drawing.Color]::FromArgb(30, 122, 70); Medio = [Drawing.Color]::FromArgb(203, 234, 213); Claro = [Drawing.Color]::FromArgb(235, 247, 239) }
}

# Barra de título de color (Windows 11; en Windows 10 queda la normal)
function Set-ColorTitulo($ventana, [Drawing.Color]$fondo) {
    try {
        $c = [int]$fondo.R -bor ([int]$fondo.G -shl 8) -bor ([int]$fondo.B -shl 16)
        $blanco = 0xFFFFFF
        [void][Win32.Dwm]::DwmSetWindowAttribute($ventana.Handle, 35, [ref]$c, 4)        # color de la barra
        [void][Win32.Dwm]::DwmSetWindowAttribute($ventana.Handle, 36, [ref]$blanco, 4)   # texto en blanco
    } catch { }
}

$Carpeta    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ApiBase    = 'https://api.bcra.gob.ar'

# ---------- Dónde se guarda el historial ----------
# Puede estar solo en esta PC (carpeta HISTORIAL del programa) o en Google Drive, compartido entre las PCs.
# La elección queda en config.txt (HISTORIAL=...). La primera vez que se abre en una PC, pregunta.

$ArchConfig      = Join-Path $Carpeta 'config.txt'
$HistorialLocal  = Join-Path $Carpeta 'HISTORIAL'
$SubcarpetaDrive = '001 - CLAUDE - CONSULTA CUIT BCRA\HISTORIAL'

function Set-Historial([string]$ruta) {
    $script:Historial     = $ruta
    $script:CarpetaPdf    = Join-Path $ruta 'PDF'
    $script:ArchGuardCuit = Join-Path $ruta 'Guardados CUIT.csv'
    $script:ArchGuardCheq = Join-Path $ruta 'Guardados cheques.csv'
}

function Find-MiUnidad {
    $candidatos = @("$env:USERPROFILE\Mi unidad", "$env:USERPROFILE\My Drive")
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) { $candidatos += (Join-Path $d.Root 'Mi unidad'), (Join-Path $d.Root 'My Drive') }
    foreach ($c in $candidatos) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Get-ResumenHistorial([string]$ruta) {
    $cuenta = { param($a) if (Test-Path -LiteralPath $a) { @(Import-Csv $a -Delimiter ';' -Encoding UTF8).Count } else { 0 } }
    [pscustomobject]@{
        Cuit      = & $cuenta (Join-Path $ruta 'Guardados CUIT.csv')
        Cheques   = & $cuenta (Join-Path $ruta 'Guardados cheques.csv')
        Consultas = (& $cuenta (Join-Path $ruta 'Consultas.csv')) + (& $cuenta (Join-Path $ruta 'Cheques denunciados.csv'))
    }
}

# Junta el historial de esta PC con el de Drive (no se pierde nada de ninguno de los dos)
function Merge-Historial([string]$origen, [string]$destino) {
    if (-not (Test-Path -LiteralPath $origen)) { return }
    New-Item -ItemType Directory -Path $destino -Force | Out-Null
    $claves = @{ 'Guardados CUIT.csv' = { param($x) $x.CUIT }; 'Guardados cheques.csv' = { param($x) '{0}|{1}|{2}|{3}' -f [int]$x.CodigoBanco, $x.NroCheque, $x.Sucursal, $x.Cuenta } }
    foreach ($f in (Get-ChildItem -LiteralPath $origen -Filter *.csv)) {
        $dest = Join-Path $destino $f.Name
        $nuevos = @(Import-Csv $f.FullName -Delimiter ';' -Encoding UTF8)
        if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $f.FullName $dest; continue }
        $hay = @(Import-Csv $dest -Delimiter ';' -Encoding UTF8)
        if ($claves.ContainsKey($f.Name)) {
            $sb = $claves[$f.Name]
            $ya = @{}; foreach ($x in $hay) { $ya[(& $sb $x)] = $true }
            $agregar = @($nuevos | Where-Object { -not $ya[(& $sb $_)] })
            if ($agregar.Count) { @($hay) + $agregar | Export-Csv $dest -NoTypeInformation -Delimiter ';' -Encoding UTF8 }
        } elseif ($nuevos.Count) {
            $nuevos | Export-Csv $dest -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8 -Force
        }
    }
    $pdf = Join-Path $origen 'PDF'
    if (Test-Path -LiteralPath $pdf) {
        New-Item -ItemType Directory -Path (Join-Path $destino 'PDF') -Force | Out-Null
        Copy-Item -Path (Join-Path $pdf '*') -Destination (Join-Path $destino 'PDF') -Force
    }
}

function Select-Historial([switch]$Preguntar) {
    $ruta = $null
    if (-not $Preguntar -and (Test-Path -LiteralPath $ArchConfig)) {
        $linea = Get-Content -LiteralPath $ArchConfig -Encoding UTF8 | Where-Object { $_ -like 'HISTORIAL=*' } | Select-Object -First 1
        if ($linea) { $ruta = $linea.Substring(10).Trim() }
    }
    if ($ruta) {
        if ($ruta -ne 'LOCAL' -and -not (Test-Path -LiteralPath (Split-Path $ruta -Parent))) {
            [Windows.Forms.MessageBox]::Show("No encuentro la carpeta de Google Drive del historial:`n$ruta`n`n¿Está abierto Google Drive? Por ahora uso el historial de esta PC.", 'Consulta CUIT BCRA', 'OK', 'Warning') | Out-Null
            Set-Historial $HistorialLocal; $script:ModoHistorial = 'Solo esta PC (Drive no disponible)'; return
        }
        if ($ruta -eq 'LOCAL') { Set-Historial $HistorialLocal; $script:ModoHistorial = 'Solo esta PC' }
        else { Set-Historial $ruta; $script:ModoHistorial = 'Google Drive (compartido entre tus PCs)' }
        return
    }

    # Primera vez en esta PC (o pidió cambiar): preguntar
    $elegido = 'LOCAL'
    $mi = Find-MiUnidad
    if ($mi) {
        $enDrive = Join-Path $mi $SubcarpetaDrive
        $r = Get-ResumenHistorial $enDrive
        if (($r.Cuit + $r.Cheques + $r.Consultas) -gt 0) {
            $msg = "Encontré un historial guardado en Google Drive (de tus otras PCs):`n`n" +
                   "   • $($r.Cuit) CUIT guardados`n   • $($r.Cheques) cheques guardados`n   • $($r.Consultas) consultas`n`n" +
                   "¿Querés tomar ese historial en esta PC?`n`n" +
                   "SÍ = usar ese historial (compartido: lo que guardes acá se ve en las otras PCs)`n" +
                   "NO = empezar un historial nuevo, solo en esta PC"
            if ([Windows.Forms.MessageBox]::Show($msg, 'Consulta CUIT BCRA - Historial', 'YesNo', 'Question') -eq 'Yes') { $elegido = $enDrive }
        } else {
            $msg = "¿Querés guardar el historial en Google Drive?`n`n" +
                   "SÍ = se guarda en Google Drive y lo podés tomar desde tus otras PCs`n" +
                   "NO = queda solo en esta PC"
            if ([Windows.Forms.MessageBox]::Show($msg, 'Consulta CUIT BCRA - Historial', 'YesNo', 'Question') -eq 'Yes') { $elegido = $enDrive }
        }
        # Lo que ya había en esta PC se suma al de Drive
        if ($elegido -ne 'LOCAL') { try { Merge-Historial $HistorialLocal $elegido } catch { } }
    }
    Set-Content -LiteralPath $ArchConfig -Value "HISTORIAL=$elegido" -Encoding UTF8
    if ($elegido -eq 'LOCAL') { Set-Historial $HistorialLocal; $script:ModoHistorial = 'Solo esta PC' }
    else { Set-Historial $elegido; $script:ModoHistorial = 'Google Drive (compartido entre tus PCs)' }
}

Select-Historial

$Situaciones = @{
    0 = 'Sin deuda'
    1 = 'Normal'
    2 = 'Riesgo bajo / seguimiento especial'
    3 = 'Riesgo medio / con problemas'
    4 = 'Riesgo alto / alto riesgo de insolvencia'
    5 = 'Irrecuperable'
    6 = 'Irrecuperable por disposición técnica'
}

# ---------- API ----------

function Get-Bcra([string]$ruta) {
    # Devuelve el objeto "results", o $null si el BCRA contesta 404 (no figura).
    try {
        $r = Invoke-RestMethod -Uri ($ApiBase + $ruta) -TimeoutSec 40 -UseBasicParsing
        return $r.results
    } catch {
        $resp = $_.Exception.Response
        if ($resp -and [int]$resp.StatusCode -eq 404) { return $null }
        throw "No se pudo consultar al BCRA ($ruta): $($_.Exception.Message)"
    }
}

$script:Entidades = $null
function Get-Entidades {
    if ($null -eq $script:Entidades) {
        $script:Entidades = @{}
        try {
            foreach ($e in (Get-Bcra '/cheques/v1.0/entidades')) { $script:Entidades[[int]$e.codigoEntidad] = $e.denominacion }
        } catch { $script:Entidades = $null }
    }
    return $script:Entidades
}
function Get-NombreEntidad($codigo) {
    $ent = Get-Entidades
    if ($ent -and $ent[[int]$codigo]) { return $ent[[int]$codigo] } else { return "Entidad $codigo" }
}

function Test-Cuit([string]$cuit) {
    if ($cuit -notmatch '^\d{11}$') { return $false }
    $mult = 5,4,3,2,7,6,5,4,3,2
    $suma = 0
    for ($i = 0; $i -lt 10; $i++) { $suma += [int]::Parse($cuit[$i]) * $mult[$i] }
    $dv = 11 - ($suma % 11)
    if ($dv -eq 11) { $dv = 0 }
    if ($dv -eq 10) { $dv = 9 }
    return $dv -eq [int]::Parse($cuit[10])
}

function Format-Cuit([string]$c) { '{0}-{1}-{2}' -f $c.Substring(0,2), $c.Substring(2,8), $c.Substring(10,1) }
function Format-Periodo([string]$p) { if ($p -match '^(\d{4})(\d{2})$') { "$($Matches[2])/$($Matches[1])" } else { $p } }
function Format-Plata($n) { '$ ' + ([decimal]$n).ToString('N2', [Globalization.CultureInfo]'es-AR') }
function Format-Fecha($f) { if ("$f" -match '^(\d{4})-(\d{2})-(\d{2})') { "$($Matches[3])/$($Matches[2])/$($Matches[1])" } else { "$f" } }

# Texto en minúsculas y sin acentos, para buscar
function Get-Norm([string]$t) {
    $d = "$t".ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    -join ($d.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
}
function Test-Coincide([string]$texto, [string]$buscado) {
    $t = Get-Norm $texto
    foreach ($p in ((Get-Norm $buscado) -split '\s+' | Where-Object { $_ })) { if (-not $t.Contains($p)) { return $false } }
    return $true
}

# ---------- Guardados (CSV en HISTORIAL) ----------

function Read-Guardados($arch) {
    $l = New-Object Collections.ArrayList
    if (Test-Path $arch) { foreach ($g in (Import-Csv $arch -Delimiter ';' -Encoding UTF8)) { [void]$l.Add($g) } }
    return ,$l
}
function Write-Guardados($arch, $lista) {
    if (-not (Test-Path $Historial)) { New-Item -ItemType Directory -Path $Historial | Out-Null }
    if ($lista.Count -eq 0) { if (Test-Path $arch) { Remove-Item $arch -Force }; return }
    $lista | Export-Csv -Path $arch -NoTypeInformation -Delimiter ';' -Encoding UTF8
}
$script:GCuit = Read-Guardados $ArchGuardCuit
$script:GCheq = Read-Guardados $ArchGuardCheq

# Vuelve a leer los guardados del disco (otra PC pudo haberlos cambiado por Drive)
function Sync-Guardados {
    $script:GCuit = Read-Guardados $ArchGuardCuit
    $script:GCheq = Read-Guardados $ArchGuardCheq
}

function Get-ClaveCheque($g) { '{0}|{1}|{2}|{3}' -f [int]$g.CodigoBanco, $g.NroCheque, $g.Sucursal, $g.Cuenta }

# ---------- Salida (pantalla + registro para el PDF) ----------
# Cada solapa tiene su RichTextBox y su lista de líneas; Out-Linea escribe en la solapa activa ($script:Sal).

function New-Salida($box) { [pscustomobject]@{ Box = $box; Lineas = New-Object Collections.ArrayList; Titulo = ''; Archivo = '' } }

function Out-Linea([string]$texto = '', [string]$color = 'Black', [switch]$Negrita, [int]$Tam = 10) {
    $box = $script:Sal.Box
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = [Drawing.Color]::$color
    $estilo = if ($Negrita) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $box.SelectionFont = New-Object Drawing.Font('Consolas', $Tam, $estilo)
    $box.AppendText($texto + "`r`n")
    [void]$script:Sal.Lineas.Add([pscustomobject]@{ Texto = $texto; Color = $color; Negrita = [bool]$Negrita; Tam = $Tam })
}

function Clear-Salida {
    $script:Sal.Box.Clear()
    $script:Sal.Lineas.Clear()
    $script:Sal.Titulo = ''
    $script:Sal.Archivo = ''
}

function Get-Edge {
    foreach ($p in "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Save-Pdf($sal) {
    if ($sal.Lineas.Count -eq 0) { return }
    $edge = Get-Edge
    if (-not $edge) { [Windows.Forms.MessageBox]::Show('No encontré Microsoft Edge, que es el que arma el PDF.', 'PDF') | Out-Null; return }
    if (-not (Test-Path $CarpetaPdf)) { New-Item -ItemType Directory -Path $CarpetaPdf -Force | Out-Null }

    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('<!doctype html><html><head><meta charset="utf-8"><title>' + [Net.WebUtility]::HtmlEncode($sal.Titulo) + '</title><style>')
    [void]$sb.Append('@page{size:A4;margin:12mm} body{font-family:Consolas,monospace;margin:0} div{white-space:pre;line-height:1.35;min-height:1em}')
    [void]$sb.Append('</style></head><body>')
    foreach ($l in $sal.Lineas) {
        $c = [Drawing.Color]::FromName($l.Color)
        $hex = '#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B
        $peso = if ($l.Negrita) { 'bold' } else { 'normal' }
        $tam = [Math]::Round($l.Tam * 0.82, 1)
        [void]$sb.Append("<div style=""color:$hex;font-weight:$peso;font-size:${tam}pt"">" + [Net.WebUtility]::HtmlEncode($l.Texto) + '</div>')
    }
    [void]$sb.Append('</body></html>')

    $tmp = Join-Path $env:TEMP 'ConsultaCUIT-BCRA'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $html = Join-Path $tmp 'informe.html'
    [IO.File]::WriteAllText($html, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))

    $nombre = ($sal.Archivo -replace '[\\/:*?"<>|]', '') + ' ' + (Get-Date -Format 'yyyy-MM-dd HHmm') + '.pdf'
    $pdf = Join-Path $CarpetaPdf $nombre
    if (Test-Path $pdf) { Remove-Item $pdf -Force }
    $form.Cursor = 'WaitCursor'
    try {
        $argsEdge = @('--headless', '--disable-gpu', '--no-pdf-header-footer', "--user-data-dir=`"$tmp\edge`"",
                      "--print-to-pdf=`"$pdf`"", "`"$html`"")
        Start-Process -FilePath $edge -ArgumentList $argsEdge -Wait -WindowStyle Hidden
    } finally { $form.Cursor = 'Default' }
    if (Test-Path $pdf) { Start-Process $pdf }
    else { [Windows.Forms.MessageBox]::Show('No se pudo generar el PDF.', 'PDF') | Out-Null }
}

# ---------- Pantalla ----------

$form = New-Object Windows.Forms.Form
$form.Text = 'Consultas BCRA - CUIT y cheques'
$form.Size = New-Object Drawing.Size(1100, 780)
$form.StartPosition = 'CenterScreen'
$form.WindowState = 'Maximized'
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$icono = Join-Path $Carpeta 'cheque.ico'
if (Test-Path $icono) { $form.Icon = New-Object Drawing.Icon($icono) }

$ayuda = New-Object Windows.Forms.ToolTip
$ayuda.AutoPopDelay = 15000
$script:Cues = @()   # textos de ayuda que se ven adentro de los casilleros vacíos

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Font = New-Object Drawing.Font('Segoe UI', 11)
$tabs.Padding = New-Object Drawing.Point(18, 6)
$tabs.DrawMode = 'OwnerDrawFixed'
$tabs.SizeMode = 'Fixed'
$tabs.ItemSize = New-Object Drawing.Size(230, 36)
$form.Controls.Add($tabs)

# Barra de abajo: dónde se guarda el historial + cambiarlo
$barraAbajo = New-Object Windows.Forms.StatusStrip
$barraAbajo.SizingGrip = $false
$lblModo = New-Object Windows.Forms.ToolStripStatusLabel
$lnkCambiar = New-Object Windows.Forms.ToolStripStatusLabel
$lnkCambiar.IsLink = $true
$lnkCambiar.Text = 'Cambiar'
[void]$barraAbajo.Items.Add($lblModo)
[void]$barraAbajo.Items.Add($lnkCambiar)
$form.Controls.Add($barraAbajo)
$barraAbajo.ShowItemToolTips = $true
$lnkCambiar.ToolTipText = 'Elegir de nuevo dónde se guarda el historial (Google Drive o solo esta PC)'
function Update-BarraAbajo {
    $lblModo.Text = "Historial: $($script:ModoHistorial)"
    $lblModo.ToolTipText = $script:Historial
}
$lnkCambiar.Add_Click({
    Select-Historial -Preguntar
    Sync-Guardados
    Update-BarraAbajo
    Update-BotonesGuardados
})

# Solapas pintadas: la elegida con su color fuerte y letra blanca, la otra con su color suave
$tabs.Add_DrawItem({
    $pag = $tabs.TabPages[$_.Index]
    $col = $Colores[$pag.Tag]
    $elegida = ($_.Index -eq $tabs.SelectedIndex)
    $r = $_.Bounds
    $fondo = if ($elegida) { $col.Oscuro } else { $col.Medio }
    $_.Graphics.FillRectangle((New-Object Drawing.SolidBrush($fondo)), $r)
    $letra = if ($elegida) { [Drawing.Color]::White } else { $col.Oscuro }
    $estilo = if ($elegida) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $f = New-Object Drawing.Font('Segoe UI', 11, $estilo)
    [Windows.Forms.TextRenderer]::DrawText($_.Graphics, $pag.Text, $f, $r, $letra, [Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter')
})

function New-Boton($texto, $x, $y, $ancho, $padre, $tip = '') {
    $b = New-Object Windows.Forms.Button
    $b.Text = $texto
    $b.Location = New-Object Drawing.Point($x, $y)
    $b.Size = New-Object Drawing.Size($ancho, 32)
    $b.Font = New-Object Drawing.Font('Segoe UI', 10)
    $padre.Controls.Add($b)
    if ($tip) { $ayuda.SetToolTip($b, $tip) }
    return $b
}
function New-Etiqueta($texto, $x, $y, $padre, [switch]$Negrita, $color = 'Black') {
    $l = New-Object Windows.Forms.Label
    $l.Text = $texto
    $l.Location = New-Object Drawing.Point($x, $y)
    $l.AutoSize = $true
    $estilo = if ($Negrita) { 'Bold' } else { 'Regular' }
    $l.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]$estilo)
    $l.ForeColor = [Drawing.Color]::$color
    $padre.Controls.Add($l)
    return $l
}
function New-Texto($x, $y, $ancho, $padre, $cue = '', $tip = '', $tam = 11) {
    $t = New-Object Windows.Forms.TextBox
    $t.Location = New-Object Drawing.Point($x, $y)
    $t.Width = $ancho
    $t.Font = New-Object Drawing.Font('Segoe UI', $tam)
    $padre.Controls.Add($t)
    if ($cue) { $script:Cues += ,@($t, $cue) }
    if ($tip) { $ayuda.SetToolTip($t, $tip) }
    return $t
}
function New-Caja($padre, $y) {
    # Ocupa todo lo que queda debajo del panel de campos (New-Panel)
    $box = New-Object Windows.Forms.RichTextBox
    $box.Dock = 'Fill'
    $box.ReadOnly = $true
    $box.BackColor = [Drawing.Color]::White
    $box.Font = New-Object Drawing.Font('Consolas', 10)
    $padre.Controls.Add($box)
    $box.BringToFront()
    return $box
}
function New-Panel($tab, $alto) {
    # Panel de arriba con los campos y botones
    $tab.Padding = New-Object Windows.Forms.Padding(6)
    $p = New-Object Windows.Forms.Panel
    $p.Dock = 'Top'
    $p.Height = $alto
    $tab.Controls.Add($p)
    return $p
}

# --- Solapa 1: Informe por CUIT ---
$tabCuit = New-Object Windows.Forms.TabPage
$tabCuit.Text = 'Informe por CUIT'
$tabCuit.Tag = 'CUIT'
$tabCuit.BackColor = $Colores.CUIT.Claro
$tabs.TabPages.Add($tabCuit)
$pnlCuit = New-Panel $tabCuit 88

[void](New-Etiqueta 'CUIT / CUIL del titular:' 10 16 $pnlCuit -Negrita)
$txt = New-Texto 180 12 230 $pnlCuit 'Ej: 20-12345678-9' "Escribí el CUIT o CUIL (con o sin guiones).`nTambién podés escribir un nombre o una nota de tus guardados para buscarlo." 12

$btn         = New-Boton 'Consultar'      425 10 110 $pnlCuit 'Consulta este CUIT en el BCRA (o apretá Enter)'
$btnCopiar   = New-Boton 'Copiar informe' 545 10 130 $pnlCuit 'Copia el informe para pegarlo en WhatsApp, mail, etc.'
$btnPdf      = New-Boton 'PDF'            685 10  80 $pnlCuit 'Guarda el informe en PDF y lo abre'
$btnCarpeta  = New-Boton 'Ver historial'  775 10 120 $pnlCuit 'Abre la carpeta con el historial de consultas y los PDF'
$btnGuardCuit = New-Boton 'Guardados'     905 10 140 $pnlCuit 'Tus CUIT guardados: buscalos por nombre, CUIT o nota y consultalos con doble clic'
$btnCopiar.Enabled = $false
$btnPdf.Enabled = $false

$chkCuit = New-Object Windows.Forms.CheckBox
$chkCuit.Text = 'Guardar este CUIT'
$chkCuit.Location = New-Object Drawing.Point(180, 56)
$chkCuit.AutoSize = $true
$chkCuit.Enabled = $false
$pnlCuit.Controls.Add($chkCuit)
$ayuda.SetToolTip($chkCuit, 'Tildalo para que este CUIT quede en tus Guardados, con la nota que escribas al lado')
[void](New-Etiqueta 'Nota:' 345 57 $pnlCuit)
$txtNotaCuit = New-Texto 390 53 500 $pnlCuit 'Ej: cheque Nº 4512 de cliente Pérez, vence 15/11' 'Lo que quieras recordar de este CUIT (se guarda con el tilde)' 10

$salCuit = New-Salida (New-Caja $tabCuit 92)

# --- Solapa 2: Cheques denunciados ---
$tabCheq = New-Object Windows.Forms.TabPage
$tabCheq.Text = 'Cheques denunciados'
$tabCheq.Tag = 'Cheque'
$tabCheq.BackColor = $Colores.Cheque.Claro
$tabs.TabPages.Add($tabCheq)
$pnlCheq = New-Panel $tabCheq 194

[void](New-Etiqueta 'Banco:' 10 16 $pnlCheq -Negrita)
$txtBanco = New-Texto 140 12 260 $pnlCheq 'Nombre o código: 11, 285, Macro...' "Escribí el código del banco (los 3 primeros números de la banda de abajo del cheque)`no parte del nombre: Nación = 11, Macro = 285, Credicoop = 191, Galicia = 7, Santander = 72..."
$lblBanco = New-Etiqueta '' 410 16 $pnlCheq -Negrita 'Gray'

[void](New-Etiqueta 'Nº de cheque:' 10 56 $pnlCheq -Negrita)
$txtNroCheque = New-Texto 140 52 150 $pnlCheq 'Ej: 12345678' 'El número del cheque (8 números, arriba a la derecha y en la banda de abajo)'
[void](New-Etiqueta 'Sucursal:' 305 56 $pnlCheq)
$txtSucursal = New-Texto 375 52 90 $pnlCheq 'Opcional' 'Número de sucursal del banco (3 números, en la banda de abajo después del banco)'
[void](New-Etiqueta 'Nº de cuenta:' 480 56 $pnlCheq)
$txtCuenta = New-Texto 575 52 210 $pnlCheq 'Opcional (recomendado)' "Número de cuenta del cheque (los últimos 11 números de la banda de abajo).`nSin la cuenta no se puede saber si el denunciado es justo ese cheque."

$lblBanda = New-Etiqueta 'Ayuda: en la banda de números de abajo del cheque van, en orden: banco (3) · sucursal (3) · código postal (4) · Nº de cheque (8) · Nº de cuenta (11)' 10 90 $pnlCheq -color 'Gray'

$btnCheq        = New-Boton 'Consultar'      140 118 110 $pnlCheq 'Consulta si el cheque está denunciado (o apretá Enter)'
$btnCheqCopiar  = New-Boton 'Copiar informe' 260 118 130 $pnlCheq 'Copia el informe para pegarlo en WhatsApp, mail, etc.'
$btnCheqPdf     = New-Boton 'PDF'            400 118  80 $pnlCheq 'Guarda el informe en PDF y lo abre'
$btnCheqCarpeta = New-Boton 'Ver historial'  490 118 120 $pnlCheq 'Abre la carpeta con el historial de consultas y los PDF'
$btnGuardCheq   = New-Boton 'Guardados'      620 118 140 $pnlCheq 'Tus cheques guardados: buscalos por banco, número o nota y consultalos con doble clic'
$btnCheqCopiar.Enabled = $false
$btnCheqPdf.Enabled = $false

$chkCheq = New-Object Windows.Forms.CheckBox
$chkCheq.Text = 'Guardar este cheque'
$chkCheq.Location = New-Object Drawing.Point(140, 162)
$chkCheq.AutoSize = $true
$chkCheq.Enabled = $false
$pnlCheq.Controls.Add($chkCheq)
$ayuda.SetToolTip($chkCheq, 'Tildalo para que este cheque quede en tus Guardados, con la nota que escribas al lado')
[void](New-Etiqueta 'Nota:' 320 163 $pnlCheq)
$txtNotaCheq = New-Texto 365 159 500 $pnlCheq 'Ej: me lo dio Pérez por la factura 0001-234' 'Lo que quieras recordar de este cheque (se guarda con el tilde)' 10

# Lista desplegable de bancos que coinciden con lo escrito
$lstBancos = New-Object Windows.Forms.ListBox
$lstBancos.Location = New-Object Drawing.Point(146, 46)
$lstBancos.Size = New-Object Drawing.Size(520, 220)
$lstBancos.Font = New-Object Drawing.Font('Segoe UI', 10)
$lstBancos.Visible = $false
$lstBancos.IntegralHeight = $false
$tabCheq.Controls.Add($lstBancos)
$lstBancos.BringToFront()

$salCheq = New-Salida (New-Caja $tabCheq 194)
$lstBancos.BringToFront()

function Set-Cues { foreach ($c in $script:Cues) { [void][Win32.Cue]::SendMessage($c[0].Handle, 0x1501, [IntPtr]1, $c[1]) } }

function Update-BotonesGuardados {
    $btnGuardCuit.Text = "Guardados ($($script:GCuit.Count))"
    $btnGuardCheq.Text = "Guardados ($($script:GCheq.Count))"
}

# ---------- Banco: búsqueda por nombre o código ----------

$script:Bancos = $null
$script:BancoSel = $null
$script:EligiendoBanco = $false

function Initialize-Bancos {
    if ($script:Bancos) { return }
    $ent = Get-Entidades
    if (-not $ent) { return }
    $script:Bancos = foreach ($k in ($ent.Keys | Sort-Object { $ent[$_] })) {
        [pscustomobject]@{ Codigo = [int]$k; Nombre = $ent[$k]; Texto = ('{0}  ({1:000})' -f $ent[$k], $k); Norm = (Get-Norm $ent[$k]) }
    }
}

function Find-Bancos([string]$t) {
    Initialize-Bancos
    $t = $t.Trim()
    if (-not $t -or -not $script:Bancos) { return @() }
    if ($t -match '^\d+$') {
        $n = [int]$t
        $exacto = @($script:Bancos | Where-Object { $_.Codigo -eq $n })
        $resto  = @($script:Bancos | Where-Object { $_.Codigo -ne $n -and "$($_.Codigo)".StartsWith("$n") })
        return @($exacto + $resto)
    }
    return @($script:Bancos | Where-Object { Test-Coincide $_.Nombre $t })
}

function Show-BancoElegido {
    if ($script:BancoSel) {
        $lblBanco.Text = '✔ ' + $script:BancoSel.Texto
        $lblBanco.ForeColor = [Drawing.Color]::ForestGreen
    }
}

function Select-Banco($b) {
    $script:BancoSel = $b
    $script:EligiendoBanco = $true
    $txtBanco.Text = $b.Nombre
    $txtBanco.SelectionStart = $txtBanco.TextLength
    $script:EligiendoBanco = $false
    $lstBancos.Visible = $false
    Show-BancoElegido
}

$txtBanco.Add_TextChanged({
    if ($script:EligiendoBanco) { return }
    $script:BancoSel = $null
    $t = $txtBanco.Text.Trim()
    $m = @(Find-Bancos $t)
    $lstBancos.Items.Clear()
    if (-not $t) { $lblBanco.Text = ''; $lstBancos.Visible = $false; return }
    if ($m.Count -eq 0) {
        $lblBanco.Text = if ($script:Bancos) { '✖ No encontré ese banco' } else { 'No se pudo cargar la lista de bancos (¿hay internet?)' }
        $lblBanco.ForeColor = [Drawing.Color]::Firebrick
        $lstBancos.Visible = $false
        return
    }
    # Código exacto o un único resultado: queda elegido solo
    if (($t -match '^\d+$' -and $m[0].Codigo -eq [int]$t) -or $m.Count -eq 1) { $script:BancoSel = $m[0]; Show-BancoElegido }
    else { $lblBanco.Text = "Hay $($m.Count) bancos: elegí uno de la lista"; $lblBanco.ForeColor = [Drawing.Color]::DarkOrange }
    if ($m.Count -gt 1) {
        foreach ($b in ($m | Select-Object -First 12)) { [void]$lstBancos.Items.Add($b.Texto) }
        $lstBancos.Tag = $m
        $lstBancos.Height = [Math]::Min(12, $m.Count) * ($lstBancos.Font.Height + 3) + 6
        $lstBancos.Visible = $true
        $lstBancos.BringToFront()
    } else { $lstBancos.Visible = $false }
})
$txtBanco.Add_KeyDown({
    if ($_.KeyCode -eq 'Down' -and $lstBancos.Visible) { [void]$lstBancos.Focus(); $lstBancos.SelectedIndex = 0; $_.Handled = $true }
    if ($_.KeyCode -eq 'Escape') { $lstBancos.Visible = $false }
})
$lstBancos.Add_Click({ if ($lstBancos.SelectedIndex -ge 0) { Select-Banco $lstBancos.Tag[$lstBancos.SelectedIndex]; [void]$txtNroCheque.Focus() } })
$lstBancos.Add_Enter({ $form.AcceptButton = $null })
$lstBancos.Add_Leave({ $form.AcceptButton = $btnCheq; $lstBancos.Visible = $false })
$lstBancos.Add_KeyDown({
    if ($_.KeyCode -eq 'Return' -and $lstBancos.SelectedIndex -ge 0) { Select-Banco $lstBancos.Tag[$lstBancos.SelectedIndex]; [void]$txtNroCheque.Focus(); $_.Handled = $true }
    if ($_.KeyCode -eq 'Escape') { $lstBancos.Visible = $false; [void]$txtBanco.Focus() }
})
foreach ($c in $txtNroCheque, $txtSucursal, $txtCuenta, $txtNotaCheq) { $c.Add_Enter({ $lstBancos.Visible = $false }) }

# ---------- Consulta por CUIT ----------

$script:UltCuit = $null
$script:Cargando = $false

function Invoke-Consulta {
    Sync-Guardados
    $script:Sal = $salCuit
    $texto = $txt.Text.Trim()
    $cuit = ($texto -replace '[^\d]', '')

    # Si escribió letras, se busca en los guardados
    if ($texto -match '[a-zA-ZáéíóúñÁÉÍÓÚÑ]') {
        $m = @($script:GCuit | Where-Object { Test-Coincide "$($_.CUIT) $($_.Nombre) $($_.Nota)" $texto })
        if ($m.Count -eq 1) { $cuit = ($m[0].CUIT -replace '\D', '') }
        else { Show-Guardados 'CUIT' $texto; return }
    }

    Clear-Salida
    $btnCopiar.Enabled = $false
    $btnPdf.Enabled = $false
    $chkCuit.Enabled = $false
    $script:UltCuit = $null
    if (-not (Test-Cuit $cuit)) {
        Out-Linea 'El CUIT no es válido (tienen que ser 11 números y el dígito verificador correcto).' 'Firebrick' -Negrita
        return
    }
    $txt.Text = Format-Cuit $cuit
    Out-Linea "Consultando $(Format-Cuit $cuit) en el BCRA..." 'Gray'
    $form.Cursor = 'WaitCursor'
    $btn.Enabled = $false
    [Windows.Forms.Application]::DoEvents()
    try {
        $deudas    = Get-Bcra "/CentralDeDeudores/v1.0/Deudas/$cuit"
        $cheques   = Get-Bcra "/CentralDeDeudores/v1.0/Deudas/ChequesRechazados/$cuit"
        $historico = Get-Bcra "/CentralDeDeudores/v1.0/Deudas/Historicas/$cuit"
    } catch {
        Clear-Salida
        Out-Linea $_.Exception.Message 'Firebrick' -Negrita
        Out-Linea 'Revisá la conexión a internet o probá de nuevo en un rato.' 'Gray'
        return
    } finally {
        $form.Cursor = 'Default'
        $btn.Enabled = $true
    }
    Clear-Salida

    $nombre = $null
    foreach ($r in @($deudas, $cheques, $historico)) { if ($r -and $r.denominacion) { $nombre = $r.denominacion; break } }
    $guardado = $script:GCuit | Where-Object { $_.CUIT -eq (Format-Cuit $cuit) } | Select-Object -First 1

    Out-Linea 'INFORME POR CUIT - BCRA CENTRAL DE DEUDORES' 'DimGray' -Negrita
    Out-Linea "CUIT $(Format-Cuit $cuit)" 'DimGray'
    if ($nombre) { Out-Linea $nombre 'Navy' -Negrita -Tam 15 }
    else { Out-Linea 'No figura en la Central de Deudores del BCRA (sin nombre registrado).' 'DarkOrange' -Negrita -Tam 12 }
    if ($guardado -and $guardado.Nota) { Out-Linea "Nota guardada: $($guardado.Nota)" 'Purple' -Negrita }
    Out-Linea

    # --- Cheques rechazados ---
    $listaCheques = @()
    if ($cheques -and $cheques.causales) {
        foreach ($c in $cheques.causales) {
            foreach ($ent in $c.entidades) {
                foreach ($d in $ent.detalle) {
                    $listaCheques += [pscustomobject]@{
                        Causal = $c.causal; Entidad = (Get-NombreEntidad $ent.entidad)
                        Numero = $d.nroCheque; FechaRechazo = $d.fechaRechazo; Monto = [decimal]$d.monto
                        FechaPago = $d.fechaPago; FechaPagoMulta = $d.fechaPagoMulta; EstadoMulta = $d.estadoMulta
                    }
                }
            }
        }
    }
    $impagos = @($listaCheques | Where-Object { -not $_.FechaPago })
    if ($listaCheques.Count -eq 0) {
        Out-Linea 'CHEQUES RECHAZADOS: NO TIENE' 'ForestGreen' -Negrita -Tam 13
    } else {
        $total = ($listaCheques | Measure-Object Monto -Sum).Sum
        $totalImp = ($impagos | Measure-Object Monto -Sum).Sum
        Out-Linea "CHEQUES RECHAZADOS: SÍ TIENE  ($($listaCheques.Count) cheques - $(Format-Plata $total))" 'Firebrick' -Negrita -Tam 13
        if ($impagos.Count -gt 0) { Out-Linea "  Sin pagar (sin levantar): $($impagos.Count) cheques - $(Format-Plata $totalImp)" 'Firebrick' -Negrita }
        else { Out-Linea '  Todos figuran como pagados/levantados.' 'DarkOrange' -Negrita }
        Out-Linea
        Out-Linea ('  {0,-10} {1,-12} {2,18}  {3,-12} {4,-18} {5}' -f 'Rechazo', 'Nº cheque', 'Monto', 'Pagado', 'Causal', 'Banco')
        foreach ($ch in ($listaCheques | Sort-Object FechaRechazo -Descending)) {
            $pag = if ($ch.FechaPago) { Format-Fecha $ch.FechaPago } else { 'NO' }
            $col = if ($ch.FechaPago) { 'Black' } else { 'Firebrick' }
            Out-Linea ('  {0,-10} {1,-12} {2,18}  {3,-12} {4,-18} {5}' -f (Format-Fecha $ch.FechaRechazo), $ch.Numero, (Format-Plata $ch.Monto), $pag, $ch.Causal, $ch.Entidad) $col
        }
    }
    Out-Linea

    # --- Situación actual ---
    $peorActual = 0
    if ($deudas -and $deudas.periodos) {
        $per = $deudas.periodos | Sort-Object periodo -Descending | Select-Object -First 1
        $ents = @($per.entidades)
        $peorActual = ($ents | Measure-Object situacion -Maximum).Maximum
        $totalDeuda = ($ents | Measure-Object monto -Sum).Sum
        $colorSit = if ($peorActual -le 1) { 'ForestGreen' } elseif ($peorActual -eq 2) { 'DarkOrange' } else { 'Firebrick' }
        Out-Linea "SITUACIÓN EN BANCOS (último informe: $(Format-Periodo $per.periodo)): $peorActual - $($Situaciones[[int]$peorActual])" $colorSit -Negrita -Tam 12
        Out-Linea "  Deuda total informada: $(Format-Plata ($totalDeuda * 1000))   (el BCRA informa en miles de pesos)" 'Black'
        Out-Linea
        Out-Linea ('  {0,-45} {1,-5} {2,18}  {3}' -f 'Entidad', 'Sit.', 'Deuda', 'Observaciones')
        foreach ($e in ($ents | Sort-Object situacion -Descending)) {
            $obs = @()
            if ($e.diasAtrasoPago -gt 0) { $obs += "$($e.diasAtrasoPago) días de atraso" }
            if ($e.refinanciaciones) { $obs += 'refinanciada' }
            if ($e.procesoJud) { $obs += 'PROCESO JUDICIAL' }
            if ($e.situacionJuridica) { $obs += 'situación jurídica' }
            if ($e.enRevision) { $obs += 'en revisión' }
            $col = if ($e.situacion -le 1) { 'Black' } elseif ($e.situacion -eq 2) { 'DarkOrange' } else { 'Firebrick' }
            $nom = if ($e.entidad.Length -gt 45) { $e.entidad.Substring(0, 44) + '…' } else { $e.entidad }
            Out-Linea ('  {0,-45} {1,-5} {2,18}  {3}' -f $nom, $e.situacion, (Format-Plata ($e.monto * 1000)), ($obs -join ', ')) $col
        }
    } else {
        Out-Linea 'SITUACIÓN EN BANCOS: no registra deudas en el último informe.' 'ForestGreen' -Negrita -Tam 12
    }
    Out-Linea

    # --- Historial 24 meses ---
    $peorHist = 0
    if ($historico -and $historico.periodos) {
        Out-Linea 'HISTORIAL (peor situación de cada mes, últimos 24 meses):' 'Navy' -Negrita
        $linea = '  '
        $n = 0
        foreach ($p in ($historico.periodos | Sort-Object periodo -Descending)) {
            $max = (@($p.entidades) | Measure-Object situacion -Maximum).Maximum
            if ($max -gt $peorHist) { $peorHist = $max }
            $linea += ('{0}: {1}   ' -f (Format-Periodo $p.periodo), $max)
            $n++
            if ($n % 6 -eq 0) { Out-Linea $linea; $linea = '  ' }
        }
        if ($linea.Trim()) { Out-Linea $linea }
        $colH = if ($peorHist -le 1) { 'ForestGreen' } elseif ($peorHist -eq 2) { 'DarkOrange' } else { 'Firebrick' }
        Out-Linea "  Peor situación en 24 meses: $peorHist - $($Situaciones[[int]$peorHist])" $colH -Negrita
        Out-Linea
    }

    Out-Linea 'Situaciones: 1 Normal | 2 Riesgo bajo | 3 Riesgo medio | 4 Riesgo alto | 5 Irrecuperable | 6 Irrec. disp. técnica' 'Gray'
    Out-Linea "Fuente: BCRA Central de Deudores - consultado el $(Get-Date -Format 'dd/MM/yyyy HH:mm')" 'Gray'

    $script:Sal.Titulo = "Informe CUIT $(Format-Cuit $cuit)"
    $script:Sal.Archivo = "Informe CUIT $(Format-Cuit $cuit) $nombre"
    $btnCopiar.Enabled = $true
    $btnPdf.Enabled = $true
    Save-Historial $cuit $nombre $listaCheques $peorActual $peorHist

    # Datos para el tilde "Guardar"
    $txtCheques = if ($listaCheques.Count -eq 0) { 'NO' } else { "SÍ: $($listaCheques.Count) ($($impagos.Count) sin pagar)" }
    $script:UltCuit = [pscustomobject]@{
        CUIT = (Format-Cuit $cuit); Nombre = $nombre; Nota = ''; Guardado = (Get-Date -Format 'dd/MM/yyyy')
        UltimaConsulta = (Get-Date -Format 'dd/MM/yyyy HH:mm'); ChequesRechazados = $txtCheques
        Situacion = "$peorActual - $($Situaciones[[int]$peorActual])"
    }
    $script:Cargando = $true
    if ($guardado) {
        $guardado.Nombre = $nombre; $guardado.UltimaConsulta = $script:UltCuit.UltimaConsulta
        $guardado.ChequesRechazados = $txtCheques; $guardado.Situacion = $script:UltCuit.Situacion
        Write-Guardados $ArchGuardCuit $script:GCuit
        $chkCuit.Checked = $true
        $txtNotaCuit.Text = $guardado.Nota
    } else {
        $chkCuit.Checked = $false
        $txtNotaCuit.Text = ''
    }
    $script:Cargando = $false
    $chkCuit.Enabled = $true
}

function Save-Historial($cuit, $nombre, $listaCheques, $peorActual, $peorHist) {
    try {
        if (-not (Test-Path $Historial)) { New-Item -ItemType Directory -Path $Historial | Out-Null }
        $archivo = Join-Path $Historial 'Consultas.csv'
        $impagos = @($listaCheques | Where-Object { -not $_.FechaPago })
        [pscustomobject]@{
            Fecha              = Get-Date -Format 'dd/MM/yyyy HH:mm'
            CUIT               = Format-Cuit $cuit
            Nombre             = $nombre
            ChequesRechazados  = $listaCheques.Count
            MontoRechazados    = ($listaCheques | Measure-Object Monto -Sum).Sum
            ChequesSinPagar    = $impagos.Count
            MontoSinPagar      = ($impagos | Measure-Object Monto -Sum).Sum
            SituacionActual    = $peorActual
            PeorSituacion24m   = $peorHist
        } | Export-Csv -Path $archivo -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
    } catch { }
}

# Tilde y nota de CUIT
function Update-GuardadoCuit {
    Sync-Guardados
    if ($script:Cargando -or -not $script:UltCuit) { return }
    $clave = $script:UltCuit.CUIT
    $existente = $script:GCuit | Where-Object { $_.CUIT -eq $clave } | Select-Object -First 1
    if ($chkCuit.Checked) {
        if ($existente) { $existente.Nota = $txtNotaCuit.Text.Trim() }
        else { $script:UltCuit.Nota = $txtNotaCuit.Text.Trim(); [void]$script:GCuit.Add($script:UltCuit) }
    } elseif ($existente) { $script:GCuit.Remove($existente) }
    Write-Guardados $ArchGuardCuit $script:GCuit
    Update-BotonesGuardados
}
$chkCuit.Add_CheckedChanged({ Update-GuardadoCuit })
$txtNotaCuit.Add_Leave({ if ($chkCuit.Checked) { Update-GuardadoCuit } })

# ---------- Consulta de cheque denunciado ----------

function Test-MismaCuenta($a, $b) {
    $a = ("$a" -replace '\D', '').TrimStart('0')
    $b = ("$b" -replace '\D', '').TrimStart('0')
    if (-not $a -or -not $b) { return $false }
    return ($a -eq $b) -or ($a.Length -ge 5 -and $b.EndsWith($a)) -or ($b.Length -ge 5 -and $a.EndsWith($b))
}

$script:UltCheq = $null

function Invoke-ConsultaCheque {
    Sync-Guardados
    $script:Sal = $salCheq
    Clear-Salida
    $btnCheqCopiar.Enabled = $false
    $btnCheqPdf.Enabled = $false
    $chkCheq.Enabled = $false
    $script:UltCheq = $null
    $lstBancos.Visible = $false

    $nro = ($txtNroCheque.Text -replace '\D', '')
    $suc = ($txtSucursal.Text -replace '\D', '')
    $cta = ($txtCuenta.Text -replace '\D', '')
    if (-not $script:BancoSel) {
        if ($txtBanco.Text.Trim()) { Out-Linea 'Elegí el banco de la lista que aparece debajo del casillero (o escribí su código: Nación 11, Macro 285, Credicoop 191...).' 'Firebrick' -Negrita }
        else { Out-Linea 'Falta el banco: escribí el nombre o el código (Nación 11, Macro 285, Credicoop 191...).' 'Firebrick' -Negrita }
        [void]$txtBanco.Focus()
        return
    }
    if (-not $nro) { Out-Linea 'Falta el número de cheque.' 'Firebrick' -Negrita; [void]$txtNroCheque.Focus(); return }
    $codigo = $script:BancoSel.Codigo

    Out-Linea 'Consultando en el BCRA...' 'Gray'
    $form.Cursor = 'WaitCursor'
    $btnCheq.Enabled = $false
    [Windows.Forms.Application]::DoEvents()
    try {
        $r = Get-Bcra "/cheques/v1.0/denunciados/$codigo/$nro"
    } catch {
        Clear-Salida
        Out-Linea $_.Exception.Message 'Firebrick' -Negrita
        Out-Linea 'Revisá la conexión a internet o probá de nuevo en un rato.' 'Gray'
        return
    } finally {
        $form.Cursor = 'Default'
        $btnCheq.Enabled = $true
    }
    Clear-Salida

    $banco = if ($r -and $r.denominacionEntidad) { $r.denominacionEntidad } else { $script:BancoSel.Nombre }
    $guardado = $script:GCheq | Where-Object { [int]$_.CodigoBanco -eq $codigo -and $_.NroCheque -eq $nro -and $_.Sucursal -eq $suc -and $_.Cuenta -eq $cta } | Select-Object -First 1

    Out-Linea 'CONSULTA DE CHEQUE DENUNCIADO - BCRA' 'DimGray' -Negrita
    Out-Linea ('Banco: {0} ({1:000})' -f $banco, $codigo) 'Navy' -Negrita -Tam 12
    $datos = "Cheque Nº $nro"
    if ($suc) { $datos += "   Sucursal $suc" }
    if ($cta) { $datos += "   Cuenta $cta" }
    Out-Linea $datos 'Navy' -Negrita -Tam 12
    if ($guardado -and $guardado.Nota) { Out-Linea "Nota guardada: $($guardado.Nota)" 'Purple' -Negrita }
    Out-Linea

    $resultado = ''
    if ($null -eq $r) {
        Out-Linea 'El BCRA no reconoce ese banco. Revisá el código.' 'DarkOrange' -Negrita -Tam 13
        $resultado = 'Banco no reconocido'
    } else {
        $det = @($r.detalles)
        if ($suc) { $det = @($det | Where-Object { [int]$_.sucursal -eq [int]$suc }) }
        if ($cta) { $det = @($det | Where-Object { Test-MismaCuenta $_.numeroCuenta $cta }) }

        if (-not $r.denunciado -or @($r.detalles).Count -eq 0) {
            Out-Linea 'NO FIGURA DENUNCIADO' 'ForestGreen' -Negrita -Tam 15
            Out-Linea '  Ningún cheque con ese número está denunciado en ese banco.' 'Black'
            $resultado = 'No figura denunciado'
        } elseif ($cta -and $det.Count -gt 0) {
            Out-Linea '¡ATENCIÓN! ESTE CHEQUE ESTÁ DENUNCIADO' 'Firebrick' -Negrita -Tam 15
            $resultado = 'DENUNCIADO'
        } elseif ($cta) {
            Out-Linea 'NO FIGURA DENUNCIADO PARA ESA CUENTA' 'ForestGreen' -Negrita -Tam 15
            Out-Linea "  Hay $(@($r.detalles).Count) cheque(s) con ese número denunciados en el banco, pero de otras cuentas." 'DarkOrange'
            Out-Linea '  Verificá que el número de cuenta esté bien copiado del cheque.' 'DarkOrange'
            $resultado = 'No figura para esa cuenta'
        } elseif ($suc -and $det.Count -eq 0) {
            Out-Linea 'NO FIGURA DENUNCIADO PARA ESA SUCURSAL' 'ForestGreen' -Negrita -Tam 15
            Out-Linea "  Hay $(@($r.detalles).Count) cheque(s) con ese número denunciados en otras sucursales del banco." 'DarkOrange'
            $resultado = 'No figura para esa sucursal'
        } else {
            Out-Linea "HAY $($det.Count) CHEQUE(S) CON ESE NÚMERO DENUNCIADOS EN ESE BANCO" 'DarkOrange' -Negrita -Tam 14
            Out-Linea '  El mismo número de cheque existe en muchas cuentas distintas.' 'Black'
            Out-Linea '  Cargá el Nº de cuenta (y sucursal) del cheque para saber si es el tuyo.' 'Black'
            $resultado = "Posible: $($det.Count) con ese número"
        }

        if ($det.Count -gt 0) {
            Out-Linea
            Out-Linea ('  {0,-10} {1,-16} {2}' -f 'Sucursal', 'Nº de cuenta', 'Causal')
            foreach ($d in ($det | Sort-Object sucursal, numeroCuenta)) {
                $col = if ($cta -or $suc) { 'Firebrick' } else { 'Black' }
                Out-Linea ('  {0,-10} {1,-16} {2}' -f $d.sucursal, $d.numeroCuenta, $d.causal) $col
            }
        }
        Out-Linea
        Out-Linea "Datos del BCRA actualizados al $(Format-Fecha $r.fechaProcesamiento)" 'Gray'
    }
    Out-Linea "Fuente: BCRA Cheques denunciados - consultado el $(Get-Date -Format 'dd/MM/yyyy HH:mm')" 'Gray'

    $script:Sal.Titulo = "Cheque $nro - $banco"
    $script:Sal.Archivo = "Cheque denunciado $nro $banco"
    $btnCheqCopiar.Enabled = $true
    $btnCheqPdf.Enabled = $true
    try {
        if (-not (Test-Path $Historial)) { New-Item -ItemType Directory -Path $Historial | Out-Null }
        [pscustomobject]@{
            Fecha = Get-Date -Format 'dd/MM/yyyy HH:mm'; Banco = $banco; CodigoBanco = $codigo
            NroCheque = $nro; Sucursal = $suc; Cuenta = $cta; Resultado = $resultado
        } | Export-Csv -Path (Join-Path $Historial 'Cheques denunciados.csv') -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
    } catch { }

    # Datos para el tilde "Guardar"
    $script:UltCheq = [pscustomobject]@{
        Banco = $banco; CodigoBanco = $codigo; NroCheque = $nro; Sucursal = $suc; Cuenta = $cta; Nota = ''
        Guardado = (Get-Date -Format 'dd/MM/yyyy'); UltimaConsulta = (Get-Date -Format 'dd/MM/yyyy HH:mm'); Resultado = $resultado
    }
    $script:Cargando = $true
    if ($guardado) {
        $guardado.UltimaConsulta = $script:UltCheq.UltimaConsulta; $guardado.Resultado = $resultado
        Write-Guardados $ArchGuardCheq $script:GCheq
        $chkCheq.Checked = $true
        $txtNotaCheq.Text = $guardado.Nota
    } else {
        $chkCheq.Checked = $false
        $txtNotaCheq.Text = ''
    }
    $script:Cargando = $false
    $chkCheq.Enabled = $true
}

function Update-GuardadoCheque {
    Sync-Guardados
    if ($script:Cargando -or -not $script:UltCheq) { return }
    $clave = Get-ClaveCheque $script:UltCheq
    $existente = $script:GCheq | Where-Object { (Get-ClaveCheque $_) -eq $clave } | Select-Object -First 1
    if ($chkCheq.Checked) {
        if ($existente) { $existente.Nota = $txtNotaCheq.Text.Trim() }
        else { $script:UltCheq.Nota = $txtNotaCheq.Text.Trim(); [void]$script:GCheq.Add($script:UltCheq) }
    } elseif ($existente) { $script:GCheq.Remove($existente) }
    Write-Guardados $ArchGuardCheq $script:GCheq
    Update-BotonesGuardados
}
$chkCheq.Add_CheckedChanged({ Update-GuardadoCheque })
$txtNotaCheq.Add_Leave({ if ($chkCheq.Checked) { Update-GuardadoCheque } })

# ---------- Ventana "Guardados" ----------

function Update-ListaGuardados {
    $lv = $script:gwLista
    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($g in $script:gwDatos) {
        $vals = @(foreach ($c in $script:gwCols) { "$($g.($c[1]))" })
        if ($script:gwBuscar.Text.Trim() -and -not (Test-Coincide ($vals -join ' ') $script:gwBuscar.Text)) { continue }
        $it = New-Object Windows.Forms.ListViewItem($vals[0])
        for ($i = 1; $i -lt $vals.Count; $i++) { [void]$it.SubItems.Add($vals[$i]) }
        $it.Tag = $g
        $sit = 0
        [void][int]::TryParse(("$($g.Situacion)" -split ' ')[0], [ref]$sit)
        $alerta = ($script:gwTipo -eq 'CUIT' -and ("$($g.ChequesRechazados)".StartsWith('SÍ') -or $sit -ge 3)) -or
                  ($script:gwTipo -eq 'Cheque' -and "$($g.Resultado)" -eq 'DENUNCIADO')
        if ($alerta) { $it.ForeColor = [Drawing.Color]::Firebrick }
        [void]$lv.Items.Add($it)
    }
    $lv.EndUpdate()
    $script:gwCuenta.Text = "$($lv.Items.Count) de $($script:gwDatos.Count)"
}

function Show-Guardados([string]$tipo, [string]$filtro = '') {
    Sync-Guardados
    $script:gwTipo = $tipo
    $script:gwElegido = $null
    if ($tipo -eq 'CUIT') {
        $script:gwDatos = $script:GCuit
        $script:gwCols = @(@('CUIT', 'CUIT', 120), @('Nombre', 'Nombre', 260), @('Nota', 'Nota', 260), @('Cheques rechazados', 'ChequesRechazados', 150),
                           @('Situación', 'Situacion', 150), @('Última consulta', 'UltimaConsulta', 130), @('Guardado', 'Guardado', 90))
    } else {
        $script:gwDatos = $script:GCheq
        $script:gwCols = @(@('Banco', 'Banco', 220), @('Nº cheque', 'NroCheque', 100), @('Sucursal', 'Sucursal', 70), @('Nº cuenta', 'Cuenta', 120),
                           @('Nota', 'Nota', 250), @('Resultado', 'Resultado', 170), @('Última consulta', 'UltimaConsulta', 130))
    }

    $w = New-Object Windows.Forms.Form
    $w.Text = if ($tipo -eq 'CUIT') { 'Guardados - CUIT' } else { 'Guardados - Cheques' }
    $w.Size = New-Object Drawing.Size(1180, 560)
    $w.StartPosition = 'CenterParent'
    $w.Font = New-Object Drawing.Font('Segoe UI', 10)
    if ($form.Icon) { $w.Icon = $form.Icon }

    $arriba = New-Object Windows.Forms.Panel
    $arriba.Dock = 'Top'
    $arriba.Height = 50
    $w.Controls.Add($arriba)
    $l = New-Object Windows.Forms.Label
    $l.Text = 'Buscar:'
    $l.Location = New-Object Drawing.Point(10, 15)
    $l.AutoSize = $true
    $arriba.Controls.Add($l)
    $script:gwBuscar = New-Object Windows.Forms.TextBox
    $script:gwBuscar.Location = New-Object Drawing.Point(70, 11)
    $script:gwBuscar.Width = 400
    $script:gwBuscar.Font = New-Object Drawing.Font('Segoe UI', 11)
    $script:gwBuscar.Text = $filtro
    $arriba.Controls.Add($script:gwBuscar)
    $script:gwCuenta = New-Object Windows.Forms.Label
    $script:gwCuenta.Location = New-Object Drawing.Point(480, 15)
    $script:gwCuenta.AutoSize = $true
    $script:gwCuenta.ForeColor = [Drawing.Color]::Gray
    $arriba.Controls.Add($script:gwCuenta)

    $bCons = New-Object Windows.Forms.Button
    $bCons.Text = 'Consultar'
    $bCons.Location = New-Object Drawing.Point(620, 9)
    $bCons.Size = New-Object Drawing.Size(110, 32)
    $arriba.Controls.Add($bCons)
    $bQuit = New-Object Windows.Forms.Button
    $bQuit.Text = 'Quitar de guardados'
    $bQuit.Location = New-Object Drawing.Point(740, 9)
    $bQuit.Size = New-Object Drawing.Size(160, 32)
    $arriba.Controls.Add($bQuit)
    $bCerrar = New-Object Windows.Forms.Button
    $bCerrar.Text = 'Cerrar'
    $bCerrar.Location = New-Object Drawing.Point(910, 9)
    $bCerrar.Size = New-Object Drawing.Size(90, 32)
    $bCerrar.DialogResult = 'Cancel'
    $arriba.Controls.Add($bCerrar)
    $w.CancelButton = $bCerrar
    $w.AcceptButton = $bCons

    $script:gwLista = New-Object Windows.Forms.ListView
    $script:gwLista.View = 'Details'
    $script:gwLista.FullRowSelect = $true
    $script:gwLista.GridLines = $true
    $script:gwLista.MultiSelect = $false
    $script:gwLista.HideSelection = $false
    $w.Padding = New-Object Windows.Forms.Padding(8)
    $script:gwLista.Dock = 'Fill'
    foreach ($c in $script:gwCols) { [void]$script:gwLista.Columns.Add($c[0], $c[2]) }
    $w.Controls.Add($script:gwLista)
    $script:gwLista.BringToFront()

    $elegir = {
        if ($script:gwLista.SelectedItems.Count -eq 0 -and $script:gwLista.Items.Count -eq 1) { $script:gwLista.Items[0].Selected = $true }
        if ($script:gwLista.SelectedItems.Count -gt 0) {
            $script:gwElegido = $script:gwLista.SelectedItems[0].Tag
            $script:gwVentana.DialogResult = 'OK'
        }
    }
    $bCons.Add_Click($elegir)
    $script:gwLista.Add_DoubleClick($elegir)
    $bQuit.Add_Click({
        if ($script:gwLista.SelectedItems.Count -eq 0) { return }
        $g = $script:gwLista.SelectedItems[0].Tag
        $nom = if ($script:gwTipo -eq 'CUIT') { "$($g.CUIT) $($g.Nombre)" } else { "cheque $($g.NroCheque) de $($g.Banco)" }
        if ([Windows.Forms.MessageBox]::Show("¿Quitar $nom de los guardados?", 'Guardados', 'YesNo', 'Question') -ne 'Yes') { return }
        $script:gwDatos.Remove($g)
        if ($script:gwTipo -eq 'CUIT') {
            Write-Guardados $ArchGuardCuit $script:GCuit
            if ($script:UltCuit -and $script:UltCuit.CUIT -eq $g.CUIT) { $script:Cargando = $true; $chkCuit.Checked = $false; $txtNotaCuit.Text = ''; $script:Cargando = $false }
        } else {
            Write-Guardados $ArchGuardCheq $script:GCheq
            if ($script:UltCheq -and (Get-ClaveCheque $script:UltCheq) -eq (Get-ClaveCheque $g)) { $script:Cargando = $true; $chkCheq.Checked = $false; $txtNotaCheq.Text = ''; $script:Cargando = $false }
        }
        Update-BotonesGuardados
        Update-ListaGuardados
    })
    $script:gwBuscar.Add_TextChanged({ Update-ListaGuardados })
    $script:gwBuscar.Add_KeyDown({ if ($_.KeyCode -eq 'Down' -and $script:gwLista.Items.Count) { [void]$script:gwLista.Focus(); $script:gwLista.Items[0].Selected = $true } })
    $w.BackColor = $Colores[$tipo].Claro
    $w.Add_Shown({ Set-ColorTitulo $script:gwVentana $Colores[$script:gwTipo].Oscuro; [void][Win32.Cue]::SendMessage($script:gwBuscar.Handle, 0x1501, [IntPtr]1, 'Nombre, CUIT, banco, número o nota...'); [void]$script:gwBuscar.Focus(); $script:gwBuscar.SelectionStart = $script:gwBuscar.TextLength })

    $script:gwVentana = $w
    Update-ListaGuardados
    $res = $w.ShowDialog($form)
    $w.Dispose()
    if ($res -ne 'OK' -or -not $script:gwElegido) { return }

    $g = $script:gwElegido
    if ($tipo -eq 'CUIT') {
        $tabs.SelectedTab = $tabCuit
        $txt.Text = $g.CUIT
        Invoke-Consulta
    } else {
        $tabs.SelectedTab = $tabCheq
        Initialize-Bancos
        $b = $script:Bancos | Where-Object { $_.Codigo -eq [int]$g.CodigoBanco } | Select-Object -First 1
        if (-not $b) { $b = [pscustomobject]@{ Codigo = [int]$g.CodigoBanco; Nombre = $g.Banco; Texto = ('{0}  ({1:000})' -f $g.Banco, [int]$g.CodigoBanco) } }
        Select-Banco $b
        $txtNroCheque.Text = $g.NroCheque
        $txtSucursal.Text = $g.Sucursal
        $txtCuenta.Text = $g.Cuenta
        Invoke-ConsultaCheque
    }
}

# ---------- Eventos ----------

function Open-Historial {
    if (-not (Test-Path $Historial)) { New-Item -ItemType Directory -Path $Historial | Out-Null }
    Start-Process explorer.exe $Historial
}

$btn.Add_Click({ Invoke-Consulta })
$btnCopiar.Add_Click({ [Windows.Forms.Clipboard]::SetText($salCuit.Box.Text) })
$btnPdf.Add_Click({ Save-Pdf $salCuit })
$btnCarpeta.Add_Click({ Open-Historial })
$btnGuardCuit.Add_Click({ Show-Guardados 'CUIT' })

$btnCheq.Add_Click({ Invoke-ConsultaCheque })
$btnCheqCopiar.Add_Click({ [Windows.Forms.Clipboard]::SetText($salCheq.Box.Text) })
$btnCheqPdf.Add_Click({ Save-Pdf $salCheq })
$btnCheqCarpeta.Add_Click({ Open-Historial })
$btnGuardCheq.Add_Click({ Show-Guardados 'Cheque' })

# Enter consulta en la solapa que esté abierta
$tabs.Add_SelectedIndexChanged({
    Set-ColorTitulo $form $Colores[$tabs.SelectedTab.Tag].Oscuro
    if ($tabs.SelectedTab -eq $tabCheq) {
        $form.AcceptButton = $btnCheq
        if (-not $script:Bancos) { $form.Cursor = 'WaitCursor'; Initialize-Bancos; $form.Cursor = 'Default' }
        [void]$txtBanco.Focus()
    } else { $form.AcceptButton = $btn; [void]$txt.Focus() }
})
$form.AcceptButton = $btn
Update-BotonesGuardados
Update-BarraAbajo
$form.Add_Shown({ Set-ColorTitulo $form $Colores.CUIT.Oscuro; Set-Cues; [void]$txt.Focus() })

# Permite abrirlo con un CUIT ya cargado: ConsultaCUIT.ps1 20-12345678-9
if ($args.Count -gt 0) { $txt.Text = $args[0]; $form.Add_Shown({ Invoke-Consulta }) }

[void]$form.ShowDialog()
