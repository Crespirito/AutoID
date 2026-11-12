<#
.SYNOPSIS
    Menú orquestador para entornos de laboratorio en Entra ID.
.DESCRIPTION
    Punto de entrada del programa. Gestiona:
      - Conexión App-Only con certificado (estricta).
      - Configuración persistente (nivel, App-Only).
      - Carga de capacidades desde lib_caps/.
      - Delegación en creauto.ps1, creamanual.ps1, clean.ps1.
      - Flujo de vulnerabilidades: [5] Crear, [6] Ver.

    ACCIONES BLOQUEADAS:
    Algunas acciones dependen de correcciones que aún no se han aplicado
    (ver $script:AccionesDesbloqueadas). Si el usuario intenta ejecutarlas,
    se muestra un aviso claro y no se ejecuta nada. Esto permite probar la
    conexión sin riesgo mientras se completan las fases de corrección.
.NOTES
    Requiere PowerShell 7.
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

# Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) {
    throw 'Ejecuta este script como archivo .ps1, no pegado en consola.'
}

# ============================================================
# CARGA DE LIBRERÍAS
# ============================================================
# ============================================================
# CARGA DE LIBRERÍAS (orden de dependencias)
# ============================================================
$__libs = @(
    'lib_ui.ps1',           # base: Write-Lab*
    'lib_config.ps1',       # base: Get-LabConfig, Update-LabConfig
    'lib_graph.ps1',        # base: Connect-LabGraph, Get-MgContext helpers
    'lib_niveles.ps1',      # base: Get-LabNivelActual, Get-LabNivelEfectivo
    'lib_caps.ps1',         # expone Get-LabCapacidades, Initialize-LabCapacidades
    'lib_manifiesto.ps1',   # expone Get-LabManifiesto, Add-LabManifiesto*
    'lib_escenarios.ps1',   # DEPENDE de lib_caps.ps1 (Get-LabCapacidad, Get-LabCapacidades)
    'lib_creadores.ps1',    # DEPENDE de varias
    'lib_helpers.ps1'       # base: Get-LabPropSegura, Get-LabSeed, Get-LabTenantDomainSafe
)

foreach ($lib in $__libs) {
    $p = Join-Path $PSScriptRoot $lib
    if (-not (Test-Path -LiteralPath $p)) {
        throw "menu.ps1: no se encuentra la librería '$lib' en '$p'."
    }
    try {
        . $p
    } catch {
        throw "menu.ps1: error cargando '$lib': $($_.Exception.Message)"
    }
}
Remove-Variable __libs -ErrorAction SilentlyContinue

# ============================================================
# RUTAS A LOS SCRIPTS HIJOS
# ============================================================
$ScriptAuto    = Join-Path $PSScriptRoot 'creauto.ps1'
$ScriptManual  = Join-Path $PSScriptRoot 'creamanual.ps1'
$ScriptCleanup = Join-Path $PSScriptRoot 'clean.ps1'

# ============================================================
# FLAGS DE DESBLOQUEO DE ACCIONES
# ============================================================
# Acciones que se pueden ejecutar. Las que no están aquí se bloquean
# con un aviso. Añadir en su fase correspondiente:
#   '1' -> creauto.ps1 (depende de Invoke-LabValidacionEscenario + N14 + N16 + N17 + N21)
#   '2' -> creamanual.ps1 (depende de creauto.ps1, porque delega en él)
#   '3' -> clean.ps1 (depende de N12 + N3 + N14)
#   '5' -> cap_vulnerabilidades.ps1 (depende de N14 + N16)
$script:AccionesDesbloqueadas = @('1', '2', '4', '5', '6')

$script:MotivosBloqueo = @{
    '1' = 'Pendiente de la fase cap_*.ps1 (N14, N16, N17, N21) y de Invoke-LabValidacionEscenario.'
    '2' = 'Pendiente de creauto.ps1 (la creación manual delega en él al finalizar).'
    '3' = 'Pendiente de la fase clean.ps1 (N12) y de la fase cap_*.ps1 (N3, N14).'
    '5' = 'Pendiente de la fase cap_vulnerabilidades.ps1 (N14) y cap_metodos_auth.ps1 (N16).'
}

# ============================================================
# ESTADO DEL MENÚ
# ============================================================
$script:config = Get-LabConfig
$null = Initialize-LabCapacidades -Root (Join-Path $PSScriptRoot 'lib_caps')

# ============================================================
# FUNCIONES AUXILIARES
# ============================================================

function Invoke-EnsureSession {
    if (Test-LabGraphSession) { return $true }

    if (-not (Test-LabAppOnlyConfigComplete -Config $script:config)) {
        Write-LabWarn 'No hay configuración App-Only completa (ClientId, TenantId, Thumbprint).'
        Write-LabInfo 'Usa [S] Gestionar sesión para configurar el certificado.'
        return $false
    }

    Write-LabWarn 'No hay sesión de Graph activa. Conectando con App-Only...'
    $conectado = Connect-LabGraph `
        -ClientId              $script:config.ClientId `
        -TenantId              $script:config.TenantId `
        -CertificateThumbprint $script:config.CertificateThumbprint

    return [bool]$conectado
}

function Test-ScriptHijo {
    param([string]$Path, [string]$Nombre)
    if (-not (Test-Path -Path $Path)) {
        Write-LabError "No se encuentra el script '$Nombre' en: $Path"
        return $false
    }
    return $true
}

function Invoke-ScriptHijo {
    param([string]$Path, [hashtable]$Argumentos = @{})

    Write-Host ''
    Write-Host "Ejecutando: $(Split-Path -Path $Path -Leaf)" -ForegroundColor Green
    Write-Host '------------------------------------------------------------' -ForegroundColor Gray

    try {
        & $Path @Argumentos
    } catch {
        Write-LabError "Fallo durante la ejecución: $($_.Exception.Message)"
    }

    Write-Host '------------------------------------------------------------' -ForegroundColor Gray
}

function Test-AccionDesbloqueada {
    <#
    .SYNOPSIS
        Devuelve $true si la acción está desbloqueada, o muestra el motivo.
    #>
    param([Parameter(Mandatory = $true)][string]$Accion)

    if ($script:AccionesDesbloqueadas -contains $Accion) { return $true }

    $motivo = $null
    if ($script:MotivosBloqueo.ContainsKey($Accion)) { $motivo = $script:MotivosBloqueo[$Accion] }

    Write-LabWarn "Acción [$Accion] bloqueada."
    if (-not [string]::IsNullOrWhiteSpace($motivo)) {
        Write-LabInfo $motivo
    }
    Write-LabInfo 'Se desbloqueará automáticamente al terminar las fases de corrección correspondientes.'
    return $false
}

# ============================================================
# GESTIÓN DE SESIÓN Y CERTIFICADOS
# ============================================================

function Show-LabCertificateList {
    param(
        [Parameter(Mandatory = $true)] [array]$Certificados
    )

    Write-Host '  Certificados disponibles en Cert:\CurrentUser\My (con clave privada):' -ForegroundColor Cyan
    Write-Host ''
    if ($Certificados.Count -eq 0) {
        Write-Host '    (ninguno)' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    for ($i = 0; $i -lt $Certificados.Count; $i++) {
        $c = $Certificados[$i]
        $num = $i + 1
        Write-Host ('    [{0}] {1}' -f $num, $c.Thumbprint) -ForegroundColor White
        Write-Host ('        Subject : {0}' -f $c.Subject) -ForegroundColor Gray
        Write-Host ('        Expira  : {0}' -f $c.NotAfter.ToString('yyyy-MM-dd')) -ForegroundColor Gray
    }
    Write-Host ''
}

function Select-LabCertificate {
    <#
    .SYNOPSIS
        Muestra los certificados del store y permite seleccionar uno o importar un .pfx.
    .OUTPUTS
        El certificado seleccionado, o $null si se cancela.
    #>
    $certificados = @(Get-LabAvailableCertificates)
    Show-LabCertificateList -Certificados $certificados

    Write-Host '  Opciones:' -ForegroundColor Cyan
    Write-Host '    [número] Seleccionar un certificado de la lista'
    Write-Host '    [C]      Cargar un certificado desde fichero .pfx'
    Write-Host '    [X]      Cancelar y volver'
    Write-Host ''

    $sel = Read-Host '  Selecciona una opción'

    if ($sel -match '^(?i)x$' -or [string]::IsNullOrWhiteSpace($sel)) {
        return $null
    }

    if ($sel -match '^(?i)c$') {
        $imported = Import-LabPfxCertificate
        if ($null -eq $imported) { return $null }
        return $imported
    }

    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $certificados.Count) {
        return $certificados[[int]$sel - 1]
    }

    Write-LabWarn 'Selección inválida.'
    return $null
}

function Invoke-ConfigurarAppOnly {
    Show-LabHeader -Titulo 'CONFIGURAR CERTIFICADO APP-ONLY'

    Write-Host '  Datos actuales:' -ForegroundColor Yellow
    Write-Host "    ClientId    : $($script:config.ClientId)"
    Write-Host "    TenantId    : $($script:config.TenantId)"
    Write-Host "    Thumbprint  : $($script:config.CertificateThumbprint)"
    Write-Host ''

    $cert = Select-LabCertificate
    if ($null -eq $cert) {
        Write-LabInfo 'Configuración cancelada.'
        Start-Sleep -Seconds 1
        return
    }

    Write-Host ''
    Write-LabOk "Certificado seleccionado: $($cert.Thumbprint)"
    Write-Host "  Subject : $($cert.Subject)"
    Write-Host "  Expira  : $($cert.NotAfter.ToString('yyyy-MM-dd'))"
    Write-Host ''

    $clientId = Read-Host "  ClientId de la App [$($script:config.ClientId)]"
    if ([string]::IsNullOrWhiteSpace($clientId)) { $clientId = $script:config.ClientId }
    if ([string]::IsNullOrWhiteSpace($clientId)) {
        Write-LabWarn 'ClientId vacío. Configuración cancelada.'
        Start-Sleep -Seconds 1
        return
    }

    $tenantId = Read-Host "  TenantId [$($script:config.TenantId)]"
    if ([string]::IsNullOrWhiteSpace($tenantId)) { $tenantId = $script:config.TenantId }
    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        Write-LabWarn 'TenantId vacío. Configuración cancelada.'
        Start-Sleep -Seconds 1
        return
    }

    $cambios = @{
        ClientId              = $clientId.Trim()
        TenantId              = $tenantId.Trim()
        CertificateThumbprint = $cert.Thumbprint.Trim()
    }
    $script:config = Update-LabConfig -Cambios $cambios

    Write-LabOk 'Configuración App-Only guardada en menu_config.json.'
    Start-Sleep -Seconds 1
}

function Invoke-GestionSesion {
    while ($true) {
        Show-LabHeader -Titulo 'GESTION DE SESION (APP-ONLY)'
        $status = Get-LabGraphStatus

        if ($status) {
            Write-LabOk 'Sesión activa.'
            Write-Host "  Tenant   : $($status.TenantId)"
            if ($status.ClientId) { Write-Host "  ClientId : $($status.ClientId)" }
        } else {
            Write-LabWarn 'No hay sesión activa.'
        }

        Write-Host ''
        Write-Host '  Configuración App-Only:' -ForegroundColor Yellow
        Write-Host "    ClientId    : $($script:config.ClientId)"
        Write-Host "    TenantId    : $($script:config.TenantId)"
        Write-Host "    Thumbprint  : $($script:config.CertificateThumbprint)"
        Write-Host ''

        Write-Host '  [1] Conectar / Reconectar'
        Write-Host '  [2] Configurar certificado'
        Write-Host '  [3] Desconectar'
        Write-Host '  [0] Volver al menú principal'
        Write-Host ''

        $op = Read-Host 'Selecciona una opción'

        switch ($op) {
            '1' {
                if (-not (Test-LabAppOnlyConfigComplete -Config $script:config)) {
                    Write-LabWarn 'Faltan datos App-Only. Usa [2] para configurarlos.'
                    Wait-LabKey
                    continue
                }
                if (Test-LabGraphSession) {
                    Disconnect-LabGraph
                }
                $conectado = Connect-LabGraph `
                    -ClientId              $script:config.ClientId `
                    -TenantId              $script:config.TenantId `
                    -CertificateThumbprint $script:config.CertificateThumbprint
                if (-not $conectado) {
                    Write-LabError 'No se pudo conectar con App-Only.'
                }
                Wait-LabKey
            }
            '2' { Invoke-ConfigurarAppOnly }
            '3' { Disconnect-LabGraph; Wait-LabKey }
            '0' { return }
            default { Write-LabError 'Opción no válida.'; Start-Sleep -Seconds 1 }
        }
    }
}

# ============================================================
# ACCIONES DEL MENÚ
# ============================================================

function Invoke-CrearAutomatica {
    if (-not (Test-AccionDesbloqueada -Accion '1')) { Wait-LabKey; return }
    if (-not (Test-ScriptHijo -Path $ScriptAuto -Nombre 'creauto.ps1')) { Wait-LabKey; return }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (Test-LabManifiestoExists) {
        Write-LabWarn 'Ya existe un manifiesto pendiente. Se sobrescribirá si creas un nuevo entorno.'
        $resp = Read-Host "Escribe 'SI' para continuar"
        if ($resp -ne 'SI') {
            Write-LabInfo 'Operación cancelada.'
            Start-Sleep -Seconds 1
            return
        }
    }

    Invoke-ScriptHijo -Path $ScriptAuto
    Wait-LabKey
}

function Invoke-CrearPersonalizada {
    if (-not (Test-AccionDesbloqueada -Accion '2')) { Wait-LabKey; return }
    if (-not (Test-ScriptHijo -Path $ScriptManual -Nombre 'creamanual.ps1')) { Wait-LabKey; return }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (Test-LabManifiestoExists) {
        Write-LabWarn 'Ya existe un manifiesto pendiente. Se sobrescribirá si creas un nuevo entorno.'
        $resp = Read-Host "Escribe 'SI' para continuar"
        if ($resp -ne 'SI') {
            Write-LabInfo 'Operación cancelada.'
            Start-Sleep -Seconds 1
            return
        }
    }

    Invoke-ScriptHijo -Path $ScriptManual
    Wait-LabKey
}

function Invoke-CrearVulnerabilidad {
    if (-not (Test-AccionDesbloqueada -Accion '5')) { Wait-LabKey; return }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    $cap = Get-LabCapacidad -Nombre 'Vulnerabilidades'
    if (-not $cap) {
        Write-LabError "La capacidad 'Vulnerabilidades' no está registrada."
        Wait-LabKey
        return
    }

    # N20: copia defensiva del contexto y de la configuración
    $configCopia = $script:config.Clone()

    $ctxTest = @{
        TenantId      = (Get-MgContext).TenantId
        TenantDomain  = Get-LabTenantDomain
        Nivel         = Get-LabNivelActual -Config $configCopia
        NivelEfectivo = Get-LabNivelEfectivo -Config $configCopia
        Config        = $configCopia
    }
    if ([string]::IsNullOrWhiteSpace($ctxTest.TenantDomain)) {
        $ctxTest.TenantDomain = $ctxTest.TenantId
    }

    $t = & $cap.TestDisponible $ctxTest
    if (-not $t.Disponible) {
        Write-LabWarn $t.Motivo
        Wait-LabKey
        return
    }

    $ctxUI = @{
        TenantId      = $ctxTest.TenantId
        TenantDomain  = $ctxTest.TenantDomain
        Nivel         = $ctxTest.Nivel
        NivelEfectivo = $ctxTest.NivelEfectivo
        Config        = $configCopia.Clone()
    }

    $def = & $cap.PreguntarUI $ctxUI
    if ($null -eq $def) {
        Write-LabInfo 'Operación cancelada.'
        Wait-LabKey
        return
    }

    $errores = & $cap.ValidarDef @($def)
    if (@($errores).Count -gt 0) {
        Write-LabError 'La vulnerabilidad tiene errores de validación:'
        foreach ($e in @($errores)) { Write-Host "  - $e" -ForegroundColor Red }
        Wait-LabKey
        return
    }

    Show-LabHeader -Titulo 'RESUMEN DE VULNERABILIDAD'
    Write-Host "  Nombre : $($def.nombre)"
    Write-Host "  Tipo   : $($def.tipo)"
    Write-Host ''
    $texto = & $cap.Describir @($def)
    Write-Host "  $texto" -ForegroundColor Gray
    Write-Host ''
    Write-Host '¿Aplicar esta vulnerabilidad?' -ForegroundColor Yellow
    $resp = Read-Host "Escribe 'SI' para confirmar"
    if ($resp -ne 'SI') {
        Write-LabInfo 'Operación cancelada.'
        Wait-LabKey
        return
    }

    $snapshot = New-LabSnapshotPreLab
    $manifiesto = if (Test-LabManifiestoExists) { Get-LabManifiesto } else { $null }
    if ($null -eq $manifiesto) {
        $manifiesto = New-LabManifiestoVacio -Escenario 'manual' -Nivel (Get-LabNivelActual -Config $configCopia) -Semilla $null
        $manifiesto.tenantDomain = $ctxTest.TenantDomain
    }

    $ctxCrear = @{
        TenantId                  = $ctxTest.TenantId
        TenantDomain              = $manifiesto.tenantDomain
        Nivel                     = Get-LabNivelActual -Config $configCopia
        NivelEfectivo             = Get-LabNivelEfectivo -Config $configCopia
        Config                    = $configCopia.Clone()
        SnapshotPreLab            = $snapshot
        VulnerabilidadesExcluidas = @()
    }

    $resultados = @()
    try {
        $resultados = & $cap.Crear @($def) $ctxCrear
    } catch {
        Write-LabError "Error aplicando la vulnerabilidad: $($_.Exception.Message)"
        Wait-LabKey
        return
    }

    if (@($resultados).Count -eq 0) {
        Write-LabWarn 'No se aplicó ninguna vulnerabilidad.'
        Wait-LabKey
        return
    }

    foreach ($r in @($resultados)) {
        if ($null -eq $r) { continue }
        $capacidadAplicadora = if ($r.PSObject.Properties['capacidadAplicadora']) { $r.capacidadAplicadora } else { 'Vulnerabilidades' }
        $datos = if ($r.PSObject.Properties['datos'] -and $null -ne $r.datos) { $r.datos } else { @{} }

        $estado = if ($r.PSObject.Properties['estadoDetalle'] -and $r.estadoDetalle -eq 'preexistente') { 'preexistente' } else { 'aplicada' }

        $null = Add-LabManifiestoVulnerabilidad `
            -Manifiesto $manifiesto `
            -Nombre $def.nombre `
            -Tipo $r.tipo `
            -Capacidad $capacidadAplicadora `
            -Datos $datos `
            -Estado $estado

        Write-LabOk "Vulnerabilidad registrada: $($r.tipo) ($estado)"
    }

    $manifiestoPath = Get-LabManifiestoPath
    if (Save-LabManifiesto -Manifiesto $manifiesto -Path $manifiestoPath) {
        Write-LabOk "Manifiesto guardado."
    } else {
        Write-LabError 'No se pudo guardar el manifiesto.'
    }
    Wait-LabKey
}

function Invoke-VerVulnerabilidades {
    Show-LabHeader -Titulo 'VULNERABILIDADES EN EL MANIFIESTO'

    if (-not (Test-LabManifiestoExists)) {
        Write-LabWarn 'No hay manifiesto. No hay vulnerabilidades registradas.'
        Wait-LabKey
        return
    }

    try { $m = Get-LabManifiesto } catch {
        Write-LabError "No se pudo leer el manifiesto: $($_.Exception.Message)"
        Wait-LabKey; return
    }

    if ($null -eq $m -or @($m.vulnerabilidades).Count -eq 0) {
        Write-LabInfo 'No hay vulnerabilidades registradas en el manifiesto.'
        Wait-LabKey
        return
    }

    $i = 0
    foreach ($v in @($m.vulnerabilidades)) {
        $i++
        $color = switch ($v.estado) {
            'aplicada'     { 'Yellow' }
            'revertida'    { 'Green' }
            'preexistente' { 'DarkGray' }
            'fallida'      { 'Red' }
            'no-revertida' { 'Red' }
            default        { 'Gray' }
        }

        Write-Host ("  [{0}] {1}" -f $i, $v.nombre) -ForegroundColor Cyan
        Write-Host ("      Tipo       : {0}" -f $v.tipo)
        Write-Host ("      Capacidad  : {0}" -f $v.capacidad)
        Write-Host ("      Estado     : {0}" -f $v.estado) -ForegroundColor $color
        Write-Host ''
    }

    $pendientes = Get-LabManifiestoPendientes -Manifiesto $m
    Write-Host ("Total: {0} | Pendientes: {1}" -f @($m.vulnerabilidades).Count, @($pendientes.vulnerabilidades).Count) -ForegroundColor Gray
    Wait-LabKey
}

function Invoke-Limpiar {
    if (-not (Test-AccionDesbloqueada -Accion '3')) { Wait-LabKey; return }
    if (-not (Test-ScriptHijo -Path $ScriptCleanup -Nombre 'clean.ps1')) { Wait-LabKey; return }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (-not (Test-LabManifiestoExists)) {
        Write-LabWarn 'No hay manifiesto pendiente. Nada que limpiar.'
        Wait-LabKey
        return
    }

    Invoke-ScriptHijo -Path $ScriptCleanup -Argumentos @{ ManifiestoPath = (Get-LabManifiestoPath) }
    Wait-LabKey
}

function Invoke-VerManifiesto {
    Show-LabHeader -Titulo 'MANIFIESTO'

    if (-not (Test-LabManifiestoExists)) {
        Write-LabWarn 'No hay manifiesto pendiente.'
        Wait-LabKey
        return
    }

    try {
        $m = Get-LabManifiesto
        Write-Host "Versión           : $($m.manifestVersion)"
        Write-Host "Fecha             : $($m.fecha)"
        Write-Host "Tenant            : $($m.tenantDomain)"
        Write-Host "Escenario         : $($m.escenario)"
        Write-Host ''

        $pendientes = Get-LabManifiestoPendientes -Manifiesto $m
        Write-Host "Objetos pendientes: $($pendientes.objetos.Count)" -ForegroundColor Cyan
        foreach ($o in $pendientes.objetos) {
            Write-Host "  - [$($o.capacidad)] $($o.tipo): $($o.id)" -ForegroundColor Gray
        }
        Write-Host ''
        Write-Host "Vulnerabilidades pendientes: $($pendientes.vulnerabilidades.Count)" -ForegroundColor Cyan
        foreach ($v in $pendientes.vulnerabilidades) {
            Write-Host "  - [$($v.capacidad)] $($v.tipo): $($v.nombre) ($($v.estado))" -ForegroundColor Gray
        }
    } catch {
        Write-LabError "No se pudo leer el manifiesto: $($_.Exception.Message)"
    }

    Wait-LabKey
}

function Invoke-VerCapacidades {
    Show-LabHeader -Titulo 'CAPACIDADES DISPONIBLES'
    $nivel = Get-LabNivelActual -Config $script:config

    $ctx = @{
        TenantId     = (Get-MgContext).TenantId
        TenantDomain = Get-LabTenantDomain
        Nivel        = $nivel
        Config       = $script:config
    }
    if ([string]::IsNullOrWhiteSpace($ctx.TenantDomain)) {
        $ctx.TenantDomain = $ctx.TenantId
    }

    $capacidades = Get-LabCapacidades
    foreach ($cap in $capacidades.Values) {
        $nombre = if ($cap.ContainsKey('Descripcion') -and $cap.Descripcion) { $cap.Descripcion } else { $cap.Nombre }
        $estado = 'OK'
        try {
            $t = & $cap.TestDisponible $ctx
            if (-not $t.Disponible) { $estado = "NO ($($t.Motivo))" }
        } catch {
            $estado = "ERROR ($($_.Exception.Message))"
        }
        Write-Host ("  {0,-35} {1}" -f $nombre, $estado)
    }
    Write-Host ''
    Write-Host "Nivel actual: $nivel" -ForegroundColor Gray
    Wait-LabKey
}

function Invoke-ToggleVerbose {
    $script:config.Verbose = -not $script:config.Verbose
    $null = Save-LabConfig -Config $script:config
    Write-LabOk "Modo Verbose: $($script:config.Verbose)"
    Start-Sleep -Seconds 1
}

function Invoke-ResetConfig {
    Write-LabWarn 'Esto restaura la configuración a valores por defecto.'
    $resp = Read-Host '¿Borrar también los datos App-Only? (SI/N)'
    $datosAppOnly = @{
        ClientId              = $script:config.ClientId
        TenantId              = $script:config.TenantId
        CertificateThumbprint = $script:config.CertificateThumbprint
    }
    $script:config = Reset-LabConfig
    if ($resp -ne 'SI') {
        $script:config = Update-LabConfig -Cambios $datosAppOnly
        Write-LabInfo 'Datos App-Only conservados.'
    } else {
        Write-LabInfo 'Datos App-Only borrados.'
    }
    Write-LabOk 'Configuración reseteada.'
    Start-Sleep -Seconds 1
}

# ============================================================
# PANTALLAS DE ESTADO
# ============================================================

function Show-EstadoSesion {
    Write-Host '--- Sesion Graph ---' -ForegroundColor Yellow
    $s = Get-LabGraphStatus
    if ($s) {
        Write-Host "  Conectado : $($s.AuthType)" -ForegroundColor Green
        Write-Host "  Tenant    : $($s.TenantId)"
        if ($s.ClientId) { Write-Host "  ClientId  : $($s.ClientId)" }
    } else {
        Write-Host '  Sin sesion activa' -ForegroundColor Red
    }
    Write-Host ''
}

function Show-EstadoNivel {
    Write-Host '--- Nivel de licencia ---' -ForegroundColor Yellow

    if (-not (Test-LabGraphSession)) {
        $nivelConfig = Get-LabNivelActual -Config $script:config
        Write-Host "  Nivel      : $nivelConfig (Sin sesión activa)" -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    $detalle = Get-LabNivelEfectivoDetallado -Config $script:config
    $color = switch ($detalle.Estado) {
        'Ok'          { 'Green' }
        'SinLicencia' { 'Yellow' }
        'SinPermisos' { 'Red' }
        'SinSesion'   { 'DarkGray' }
        default       { 'Red' }
    }

    $sufijo = switch ($detalle.Estado) {
        'Ok'          { '' }
        'SinLicencia' { ' (sin licencias P1/P2)' }
        'SinPermisos' { ' (sin permisos para leer SKUs)' }
        'SinSesion'   { ' (sin sesión)' }
        default       { ' (error al consultar)' }
    }

    Write-Host "  Configurado: $($detalle.NivelConfigurado)"
    Write-Host "  Efectivo   : $($detalle.Nivel)$sufijo" -ForegroundColor $color

    if ($detalle.Estado -ne 'Ok' -and -not [string]::IsNullOrWhiteSpace($detalle.Mensaje)) {
        Write-Host "  Detalle    : $($detalle.Mensaje)" -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Show-EstadoManifiesto {
    Write-Host '--- Manifiesto ---' -ForegroundColor Yellow
    $m = Get-LabManifiestoStatus
    if ($null -eq $m) {
        Write-Host '  Sin manifiesto pendiente' -ForegroundColor DarkGray
    } elseif ($m -eq 'ilegible') {
        Write-Host '  Manifiesto presente pero ilegible' -ForegroundColor Red
    } else {
        Write-Host "  Escenario : $($m.Escenario) | Nivel: $($m.Nivel)"
        Write-Host "  Pendientes: $($m.Pendientes) objetos | $($m.Vulnerabilidades) vulnerabilidades"
    }
    Write-Host ''
}

# ============================================================
# ARRANQUE: CONEXIÓN INICIAL
# ============================================================
Show-LabHeader -Titulo 'GESTOR DE ENTORNOS DE LABORATORIO - ENTRA ID'

if (Test-LabAppOnlyConfigComplete -Config $script:config) {
    Write-LabInfo 'Conectando con App-Only...'
    $conectado = Connect-LabGraph `
        -ClientId              $script:config.ClientId `
        -TenantId              $script:config.TenantId `
        -CertificateThumbprint $script:config.CertificateThumbprint

    if (-not $conectado) {
        Write-LabError 'No se pudo establecer la sesión inicial App-Only.'
        Write-LabWarn 'El menú arrancará sin sesión. Usa [S] para configurar.'
        Wait-LabKey
    }
} else {
    Write-LabWarn 'No hay configuración App-Only completa.'
    Write-LabInfo 'Usa [S] para configurar el certificado.'
    Wait-LabKey
}

# ============================================================
# BUCLE PRINCIPAL
# ============================================================
while ($true) {
    Show-LabHeader
    Show-EstadoSesion
    Show-EstadoNivel
    Show-EstadoManifiesto

    Write-Host '--- Sistema ---' -ForegroundColor Cyan
    Write-Host '  [S] Gestionar sesion (Certificado App-Only)'
    Write-Host '  [C] Ver capacidades disponibles'
    Write-Host '  [V] Alternar Verbose'
    Write-Host '  [R] Resetear configuracion'
    Write-Host '  [0] Salir'
    Write-Host ''
    Write-Host '--- Acciones ---' -ForegroundColor Cyan

    $marcaAuto  = if ($script:AccionesDesbloqueadas -contains '1') { '' } else { '  (bloqueada)' }
    $marcaMan   = if ($script:AccionesDesbloqueadas -contains '2') { '' } else { '  (bloqueada)' }
    $marcaLim   = if ($script:AccionesDesbloqueadas -contains '3') { '' } else { '  (bloqueada)' }
    $marcaVuln  = if ($script:AccionesDesbloqueadas -contains '5') { '' } else { '  (bloqueada)' }

    Write-Host "  [1] Crear escenario automatico$marcaAuto"
    Write-Host "  [2] Crear escenario manual$marcaMan"
    Write-Host "  [3] Limpiar entorno$marcaLim"
    Write-Host '  [4] Ver manifiesto'
    Write-Host "  [5] Crear vulnerabilidad$marcaVuln"
    Write-Host '  [6] Ver vulnerabilidades'
    Write-Host ''

    $opcion = Read-Host 'Selecciona una opcion'

    switch ($opcion.ToUpper()) {
        'S' { Invoke-GestionSesion }
        'C' { Invoke-VerCapacidades }
        'V' { Invoke-ToggleVerbose }
        'R' { Invoke-ResetConfig }
        '0' {
            $null = Save-LabConfig -Config $script:config
            Disconnect-LabGraph
            Write-Host ''
            Write-LabOk 'Sesión cerrada. Saliendo...'
            exit 0
        }
        '1' { Invoke-CrearAutomatica }
        '2' { Invoke-CrearPersonalizada }
        '3' { Invoke-Limpiar }
        '4' { Invoke-VerManifiesto }
        '5' { Invoke-CrearVulnerabilidad }
        '6' { Invoke-VerVulnerabilidades }
        default {
            Write-LabError 'Opcion no valida.'
            Start-Sleep -Seconds 1
        }
    }
}