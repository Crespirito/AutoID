<#
.SYNOPSIS
    Creación automática de entorno de laboratorio en Entra ID.
.DESCRIPTION
    Flujo de creación automática de ESCENARIOS (no de vulnerabilidades):
      1. Elegir nivel de licencia (Free / P1 / P2).
      2. Elegir tipo de escenario (plantilla) o escenario concreto.
      3. Revisar resumen generado por las capacidades.
      4. Crear, con opción de parar y guardar plantilla en cualquier momento.

    Las VULNERABILIDADES no se aplican desde aquí: son una entidad
    separada que se aplica sobre objetos existentes. Se crean desde
    menu.ps1 [5] Crear vulnerabilidad.

    Las contraseñas de los usuarios se derivan de la semilla local del
    escenario (escenarios/.secrets/<escenario>.seed) y se muestran UNA
    SOLA VEZ al final.

    El snapshot pre-lab lo construye Invoke-LabCreacion automáticamente.
    Las capacidades lo consultan para no adoptar objetos preexistentes.

    La sesión de Graph la gestiona menu.ps1. Este script NO conecta ni
    desconecta; solo verifica que hay sesión activa y falla con código 1
    si no la hay (salvo en -DryRun).
.PARAMETER Escenario
    Nombre del escenario a crear (sin extensión). Si se omite, se muestra
    un menú de selección.
.PARAMETER Plantilla
    Nombre de la plantilla a usar como tipo de escenario. Si se omite,
    se muestra un menú de plantillas.
.PARAMETER ExcluirVulnerabilidad
    Nombres de vulnerabilidades a excluir. En el flujo actual de
    creauto.ps1 no hay vulnerabilidades que aplicar (no son parte del
    escenario), así que este parámetro es un no-op documentado. Se pasa
    al contexto para que, si en el futuro se añade un flujo combinado
    escenario + vulnerabilidades, ya esté cableado.
.PARAMETER DryRun
    Si se especifica, no crea nada. Solo muestra el resumen y sale.
    No requiere sesión de Graph ni semilla.
.NOTES
    Depende de lib_ui.ps1, lib_graph.ps1, lib_config.ps1,
    lib_manifiesto.ps1, lib_escenarios.ps1, lib_niveles.ps1,
<<<<<<< Updated upstream
    lib_caps.ps1, lib_creadores.ps1.
=======
    lib_caps.ps1, lib_creadores.ps1, lib_helpers.ps1.
>>>>>>> Stashed changes
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Escenario = $null,

    [Parameter(Mandatory = $false)]
    [string]$Plantilla = $null,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcluirVulnerabilidad = @(),

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# CARGA DE LIBRERÍAS
# ============================================================
. (Join-Path $PSScriptRoot 'lib_ui.ps1')
. (Join-Path $PSScriptRoot 'lib_graph.ps1')
. (Join-Path $PSScriptRoot 'lib_config.ps1')
. (Join-Path $PSScriptRoot 'lib_manifiesto.ps1')
. (Join-Path $PSScriptRoot 'lib_escenarios.ps1')
. (Join-Path $PSScriptRoot 'lib_niveles.ps1')
. (Join-Path $PSScriptRoot 'lib_caps.ps1')
. (Join-Path $PSScriptRoot 'lib_creadores.ps1')
<<<<<<< Updated upstream
=======
. (Join-Path $PSScriptRoot 'lib_helpers.ps1')
>>>>>>> Stashed changes

# ============================================================
# VERIFICACIÓN DE SESIÓN
# ============================================================
if (-not $DryRun) {
    if (-not (Test-LabGraphSession)) {
        Write-LabError 'No hay sesión de Graph activa. Ejecuta este script desde menu.ps1.'
        exit 1
    }
} else {
    Write-LabInfo 'Modo -DryRun: no se requiere sesión de Graph.'
}

# ============================================================
# ESTADO Y CONFIGURACIÓN
# ============================================================
$config = Get-LabConfig
$null = Initialize-LabCapacidades -Root (Join-Path $PSScriptRoot 'lib_caps')

# ============================================================
# FUNCIONES AUXILIARES: SEMILLA Y CONTRASEÑAS
# ============================================================

<<<<<<< Updated upstream
function Get-LabSecretsDir {
    <#
    .SYNOPSIS
        Devuelve la ruta de la carpeta de secretos locales.
    #>
    return (Join-Path $PSScriptRoot 'escenarios/.secrets')
}

function Get-LabSeed {
    <#
    .SYNOPSIS
        Obtiene o genera la semilla de un escenario.
    .OUTPUTS
        Byte[] con la semilla.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$NombreEscenario
    )

    $seedPath = Join-Path (Get-LabSecretsDir) "$NombreEscenario.seed"
    $seedDir = Split-Path -Path $seedPath -Parent

    if (-not (Test-Path -Path $seedDir)) {
        $null = New-Item -ItemType Directory -Path $seedDir -Force
    }

    if (Test-Path -Path $seedPath) {
        $b64 = (Get-Content -Path $seedPath -Raw -Encoding UTF8).Trim()
        return [Convert]::FromBase64String($b64)
    }

    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    $b64 = [Convert]::ToBase64String($bytes)
    Set-Content -Path $seedPath -Value $b64 -Encoding UTF8 -Force

    try {
        if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
            $acl = Get-Acl -Path $seedPath
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'FullControl',
                'Allow'
            )
            $acl.SetAccessRule($rule)
            Set-Acl -Path $seedPath -AclObject $acl
        }
    } catch {
        Write-LabWarn "No se pudieron restringir los permisos de $seedPath : $($_.Exception.Message)"
    }

    Write-LabInfo "Semilla generada para '$NombreEscenario' en $seedPath"
    return $bytes
}

function New-LabPasswordFromSeed {
    <#
    .SYNOPSIS
        Deriva una contraseña determinista a partir de la semilla y el UPN.
    #>
    param(
        [Parameter(Mandatory = $true)] [byte[]]$Semilla,
        [Parameter(Mandatory = $true)] [string]$Upn
    )

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = $Semilla
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Upn.ToLowerInvariant()))
    } finally {
        $hmac.Dispose()
    }

    $b64 = [Convert]::ToBase64String($hash)
    $core = ($b64 -replace '[^A-Za-z0-9]', '').Substring(0, 16)
    return "$core!Aa1"
}

# ============================================================
# SELECCIÓN DE NIVEL Y TIPO
# ============================================================

function Select-LabNivel {
    <#
    .SYNOPSIS
        Pide al operador que elija el nivel de licencia.
    .OUTPUTS
        String con el nivel elegido, o $null si se cancela.
    #>
    $niveles = Get-LabNivelesDisponibles
    if ($niveles.Count -eq 0) {
        Write-LabError 'No hay niveles disponibles (¿carpetas de capacidades vacías?).'
        return $null
    }

    Show-LabHeader -Titulo 'SELECCION DE NIVEL DE LICENCIA'
    for ($i = 0; $i -lt $niveles.Count; $i++) {
        $desc = Get-LabNivelDescripcion -Nivel $niveles[$i]
        Write-Host ('  [{0}] {1} - {2}' -f $i, $niveles[$i], $desc)
    }
    Write-Host ''

    $sel = Read-Host 'Selecciona un nivel'
    if (-not ($sel -match '^\d+$') -or [int]$sel -ge $niveles.Count) {
        Write-LabError 'Selección inválida.'
        return $null
    }
    return $niveles[[int]$sel]
}

=======
# Get-LabSecretsDir / Get-LabSeed / New-LabPasswordFromSeed viven en lib_helpers.ps1

# ============================================================
# SELECCIÓN DE NIVEL Y TIPO
# ============================================================

function Select-LabNivel {
    <#
    .SYNOPSIS
        Pide al operador que elija el nivel de licencia.
    .OUTPUTS
        String con el nivel elegido, o $null si se cancela.
    #>
    $niveles = Get-LabNivelesDisponibles
    if ($niveles.Count -eq 0) {
        Write-LabError 'No hay niveles disponibles (¿carpetas de capacidades vacías?).'
        return $null
    }

    Show-LabHeader -Titulo 'SELECCION DE NIVEL DE LICENCIA'
    for ($i = 0; $i -lt $niveles.Count; $i++) {
        $desc = Get-LabNivelDescripcion -Nivel $niveles[$i]
        Write-Host ('  [{0}] {1} - {2}' -f $i, $niveles[$i], $desc)
    }
    Write-Host ''

    $sel = Read-Host 'Selecciona un nivel'
    if (-not ($sel -match '^\d+$') -or [int]$sel -ge $niveles.Count) {
        Write-LabError 'Selección inválida.'
        return $null
    }
    return $niveles[[int]$sel]
}

>>>>>>> Stashed changes
function Select-LabTipoEscenario {
    <#
    .SYNOPSIS
        Pide al operador que elija una plantilla o un escenario.
    .OUTPUTS
        PSCustomObject con Tipo ('plantilla' o 'escenario') y Nombre,
        o $null si se cancela.
    #>
    $plantillas = Get-LabPlantillasDisponibles
    $escenarios = Get-LabEscenariosDisponibles

    Show-LabHeader -Titulo 'SELECCION DE TIPO DE ESCENARIO'

    $opciones = @()
    $i = 0
    if ($plantillas.Count -gt 0) {
        Write-Host '  Plantillas:' -ForegroundColor Cyan
        foreach ($p in $plantillas) {
            Write-Host ('    [{0}] {1}' -f $i, $p)
            $opciones += [pscustomobject]@{ Tipo = 'plantilla'; Nombre = $p }
            $i++
        }
        Write-Host ''
    }
    if ($escenarios.Count -gt 0) {
        Write-Host '  Escenarios:' -ForegroundColor Cyan
        foreach ($e in $escenarios) {
            Write-Host ('    [{0}] {1}' -f $i, $e)
            $opciones += [pscustomobject]@{ Tipo = 'escenario'; Nombre = $e }
            $i++
        }
        Write-Host ''
    }

    if ($opciones.Count -eq 0) {
        Write-LabError 'No hay plantillas ni escenarios disponibles.'
        return $null
    }

    $sel = Read-Host 'Selecciona una opción'
    if (-not ($sel -match '^\d+$') -or [int]$sel -ge $opciones.Count) {
        Write-LabError 'Selección inválida.'
        return $null
    }
    return $opciones[[int]$sel]
}
<<<<<<< Updated upstream
=======

# ============================================================
# RESOLUCIÓN DEL DOMINIO DEL TENANT
# ============================================================

function Get-LabTenantDomainResuelto {
    <#
    .SYNOPSIS
        Resuelve el dominio predeterminado verificado del tenant.
    .DESCRIPTION
        (Get-MgContext).TenantId devuelve el GUID del tenant, NO un
        dominio DNS. Usar ese GUID como sufijo de UPN provoca
        'The domain portion of the userPrincipalName property is invalid'.

        Esta función obtiene el dominio real:
          1. Get-MgDomain -> el que tenga IsDefault = $true.
          2. Fallback: Get-MgOrganization.VerifiedDomains -> IsDefault = $true.
          3. Fallback final: $null (el llamador decide).

        Solo se aceptan dominios que contengan un punto (no GUIDs).
    .OUTPUTS
        String con el dominio (ej. 'grexid.onmicrosoft.com'), o $null.
    #>
    $esDominioValido = {
        param($d)
        return (-not [string]::IsNullOrWhiteSpace($d)) -and ($d -match '\.')
    }

    try {
        $dominios = Get-MgDomain -ErrorAction Stop
        $defecto = @($dominios) | Where-Object { $_.IsDefault -eq $true } | Select-Object -First 1
        if ($defecto -and (& $esDominioValido $defecto.Id)) {
            return [string]$defecto.Id
        }
        # Si no hay marcado como default, usar el primero que parezca dominio real
        foreach ($d in @($dominios)) {
            if (& $esDominioValido $d.Id) { return [string]$d.Id }
        }
    } catch {
        Write-LabWarn "Get-MgDomain falló al resolver el dominio del tenant: $($_.Exception.Message)"
    }

    try {
        $org = Get-MgOrganization -ErrorAction Stop
        $defecto = @($org) | ForEach-Object { @($_.VerifiedDomains) } |
                   Where-Object { $_.IsDefault -eq $true } | Select-Object -First 1
        if ($defecto -and (& $esDominioValido $defecto.Name)) {
            return [string]$defecto.Name
        }
        foreach ($d in @($org | ForEach-Object { @($_.VerifiedDomains) })) {
            if (& $esDominioValido $d.Name) { return [string]$d.Name }
        }
    } catch {
        Write-LabWarn "Get-MgOrganization falló al resolver el dominio del tenant: $($_.Exception.Message)"
    }

    return $null
}
>>>>>>> Stashed changes

# ============================================================
# FLUJO PRINCIPAL
# ============================================================

# 1. Elegir nivel
<<<<<<< Updated upstream
=======
# $config es una copia local: $script:config solo existe dentro de menu.ps1.
>>>>>>> Stashed changes
if (-not $DryRun) {
    $nivelElegido = Select-LabNivel
    if (-not $nivelElegido) { exit 1 }
} else {
    $nivelElegido = Get-LabNivelActual -Config $config
}
<<<<<<< Updated upstream
=======
if ($nivelElegido) { $config['NivelLicencia'] = $nivelElegido }
>>>>>>> Stashed changes

# 2. Elegir plantilla o escenario
if (-not $Escenario -and -not $Plantilla) {
    $seleccion = Select-LabTipoEscenario
    if (-not $seleccion) { exit 1 }
    if ($seleccion.Tipo -eq 'plantilla') {
        $Plantilla = $seleccion.Nombre
    } else {
        $Escenario = $seleccion.Nombre
    }
}

# 3. Cargar el escenario normalizado
if ($Plantilla) {
    try {
        $esc = Get-LabPlantilla -Nombre $Plantilla
    } catch {
        Write-LabError "No se pudo cargar la plantilla '$Plantilla': $($_.Exception.Message)"
        exit 1
    }
} elseif ($Escenario) {
    $path = Join-Path (Get-LabEscenariosPath) "$Escenario.json"
    if (-not (Test-Path -Path $path)) {
        Write-LabError "No existe el escenario '$Escenario' en $(Get-LabEscenariosPath)."
        exit 1
    }
    try {
        $esc = ConvertTo-LabEscenarioNormalizado -Path $path
    } catch {
        Write-LabError "No se pudo cargar el escenario '$Escenario': $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-LabError 'Debes especificar un escenario o una plantilla.'
    exit 1
}

# 4. Resumen
Show-LabHeader -Titulo ('RESUMEN DEL ESCENARIO: ' + ($esc.Nombre))

if ($DryRun) {
    Write-Host '*** MODO SIMULACION (-DryRun): NO se creara nada en Entra ID ***' -ForegroundColor Yellow
    Write-Host ''
}

Write-Host "Descripcion: $($esc.Descripcion)" -ForegroundColor Gray
Write-Host "Nivel elegido: $nivelElegido" -ForegroundColor Gray
Write-Host ''

<<<<<<< Updated upstream
foreach ($nombreCap in $esc.Secciones.Keys) {
    $def = @($esc.Secciones[$nombreCap])
    if ($def.Count -eq 0) { continue }
=======
# Comprobación de seguridad: ¿Está vacío el escenario?
$tieneContenido = $false
foreach ($nombreCap in $esc.Secciones.Keys) {
    $def = @($esc.Secciones[$nombreCap])
    if ($def.Count -eq 0) { continue }
    $tieneContenido = $true
>>>>>>> Stashed changes
    $cap = Get-LabCapacidad -Nombre $nombreCap
    if (-not $cap) {
        Write-Host "  [$nombreCap] (capacidad no registrada)" -ForegroundColor Red
        continue
    }
    $texto = & $cap.Describir $def
    Write-Host "  $texto" -ForegroundColor Gray
<<<<<<< Updated upstream
=======
}

if (-not $tieneContenido) {
    Write-LabWarn 'El escenario no tiene ningún objeto para crear (todas las secciones están vacías).'
    Write-LabInfo 'Rellena el JSON del escenario o selecciona otro.'
    exit 0
>>>>>>> Stashed changes
}

if ($esc.Desconocidas.Count -gt 0) {
    Write-Host ''
    Write-LabWarn "Secciones sin capacidad registrada: $($esc.Desconocidas -join ', ')"
}
Write-Host ''

<<<<<<< Updated upstream
# 5. Validación
=======
# 5. Validación (Fix del .Count)
>>>>>>> Stashed changes
$errores = Invoke-LabValidacionEscenario -EscenarioNormalizado $esc -Contexto @{ Nivel = $nivelElegido }
if (@($errores).Count -gt 0) {
    Write-LabError 'El escenario tiene errores de validación:'
    foreach ($e in $errores) { Write-Host "  - $e" -ForegroundColor Red }
    exit 1
}

# 6. Confirmación (o salida en DryRun)
if ($DryRun) {
    Write-Host 'Simulacion completada. No se ha modificado Entra ID.' -ForegroundColor Yellow
    exit 0
}

Write-Host '¿Crear este escenario en Entra ID?' -ForegroundColor Yellow
$resp = Read-Host "Escribe 'SI' para confirmar"
if ($resp -ne 'SI') {
    Write-LabInfo 'Operación cancelada por el usuario.'
    exit 0
}

<<<<<<< Updated upstream
# 7. Derivar contraseñas
=======
# 7. Resolver dominio del tenant y derivar contraseñas
#
# (Get-MgContext).TenantId devuelve el GUID del tenant, NO un dominio DNS.
# Usarlo como sufijo de UPN provocaba:
#   [Request_BadRequest] The domain portion of the userPrincipalName
#   property is invalid. You must use one of the verified domain names...
# Por eso aquí se resuelve el dominio predeterminado verificado con
# Get-LabTenantDomainResuelto (Get-MgDomain -> Get-MgOrganization).
$tenantDomain = Get-LabTenantDomainResuelto
if ([string]::IsNullOrWhiteSpace($tenantDomain)) {
    Write-LabError 'No se pudo resolver el dominio verificado del tenant.'
    Write-LabInfo 'Comprueba que la sesión de Graph tiene permiso para leer dominios (Domain.Read.All) u organización (Organization.Read.All).'
    exit 1
}
Write-LabInfo "Dominio del tenant resuelto: $tenantDomain"

$esc | Add-Member -NotePropertyName 'TenantDomain' -NotePropertyValue $tenantDomain -Force

>>>>>>> Stashed changes
$nombreSemilla = if ($esc.Nombre) { $esc.Nombre } else { 'manual_' + (Get-Date -Format 'yyyyMMdd_HHmmss') }
$semilla = Get-LabSeed -NombreEscenario $nombreSemilla

$passwords = @{}
foreach ($nombreCap in $esc.Secciones.Keys) {
    $def = @($esc.Secciones[$nombreCap])
    if ($def.Count -eq 0) { continue }
    if ($nombreCap -eq 'Usuarios') {
<<<<<<< Updated upstream
        foreach ($u in $def) {
            $upn = $u.upn -replace '\{tenant\}', $esc.TenantDomain
=======
        foreach ($u in @($def)) {
            if ($null -eq $u -or -not ((Get-LabPropiedadValor -Objeto $u -Nombre 'upn'))) { continue }
            $upn = $u.upn -replace '\{tenant\}', $tenantDomain
>>>>>>> Stashed changes
            $passwords[$upn] = New-LabPasswordFromSeed -Semilla $semilla -Upn $upn
        }
    }
}

<<<<<<< Updated upstream
# 8. Manifiesto
$manifiesto = New-LabManifiestoVacio -Escenario $esc.Nombre -Nivel $nivelElegido -Semilla $nombreSemilla
$manifiesto.TenantDomain = (Get-MgContext).TenantId

=======
# INYECCIÓN CRÍTICA: Pasamos las contraseñas en el objeto Config
$config['Passwords'] = $passwords

# 8. Manifiesto
$manifiesto = New-LabManifiestoVacio -Escenario $esc.Nombre -Nivel $nivelElegido -Semilla $nombreSemilla
$manifiesto.TenantDomain = $tenantDomain

>>>>>>> Stashed changes
# 9. Crear con opción de parar
$detenerScript = {
    param($nombreCap, $ctx)
    Write-Host ''
    Write-Host "Capacidad a crear: $nombreCap" -ForegroundColor Cyan
    $r = Read-Host '  ¿Continuar? [SI] / [P]arar y guardar plantilla / [C]ancelar'
    if ($r -eq 'P') {
        Write-LabWarn 'Deteniendo creación. Se guardará la plantilla de lo hecho hasta ahora.'
        return $true
    }
    if ($r -eq 'C') {
        Write-LabWarn 'Creación cancelada. No se guarda nada.'
        return $true
    }
    return $false
}

$resultado = Invoke-LabCreacion -EscenarioNormalizado $esc -Manifiesto $manifiesto -Config $config -Detener $detenerScript

# 10. Si se detuvo, guardar plantilla
if ($resultado.Resultado -eq 'detenido') {
    Write-LabInfo 'Guardando plantilla del escenario parcial...'
    $nombrePlantilla = Read-Host 'Nombre de la plantilla (Enter para cancelar)'
    if (-not [string]::IsNullOrWhiteSpace($nombrePlantilla)) {
        $parcial = ConvertTo-LabEscenarioNormalizado -Raw ([pscustomobject]@{})
        $parcial.Nombre = $nombrePlantilla
        $parcial.Descripcion = "Plantilla parcial generada el $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        foreach ($nombreCap in $resultado.Contexto.ObjetosCreados.Keys) {
            $objetos = @($resultado.Contexto.ObjetosCreados[$nombreCap])
            if ($objetos.Count -eq 0) { continue }
            $defs = @()
            foreach ($o in $objetos) {
<<<<<<< Updated upstream
                if ($o.datos -and $o.datos.PSObject.Properties['upn']) {
                    $defs += [pscustomobject]@{ upn = $o.datos.upn; displayName = $o.datos.displayName }
                } elseif ($o.datos -and $o.datos.PSObject.Properties['displayName']) {
=======
                if ($o.datos -and ((Get-LabPropiedadValor -Objeto $o.datos -Nombre 'upn'))) {
                    $defs += [pscustomobject]@{ upn = $o.datos.upn; displayName = $o.datos.displayName }
                } elseif ($o.datos -and ((Get-LabPropiedadValor -Objeto $o.datos -Nombre 'displayName'))) {
>>>>>>> Stashed changes
                    $defs += [pscustomobject]@{ displayName = $o.datos.displayName }
                }
            }
            if ($defs.Count -gt 0) {
                $parcial.Secciones[$nombreCap] = $defs
            }
        }
        if (Save-LabPlantilla -EscenarioNormalizado $parcial -Nombre $nombrePlantilla) {
            Write-LabOk "Plantilla guardada: $nombrePlantilla"
        }
    }
}

# 11. Mostrar contraseñas derivadas (una sola vez)
if ($passwords.Count -gt 0) {
    Write-Host ''
    Write-Host '=== CONTRASEÑAS DERIVADAS (MOSTRAR UNA SOLA VEZ) ===' -ForegroundColor Yellow
    Write-Host 'Anota estas credenciales. No se guardan en el manifiesto ni en el JSON.' -ForegroundColor Yellow
    Write-Host 'Para reproducirlas, conserva la semilla local del escenario.' -ForegroundColor Yellow
    Write-Host ''
    foreach ($upn in $passwords.Keys) {
        Write-Host ("  {0} / {1}" -f $upn, $passwords[$upn]) -ForegroundColor Gray
    }
    Write-Host ''
}

# 12. Guardar manifiesto y log
$manifiestoPath = Get-LabManifiestoPath
if (Save-LabManifiesto -Manifiesto $manifiesto -Path $manifiestoPath) {
    Write-LabOk "Manifiesto guardado: $manifiestoPath"
} else {
    Write-LabError 'No se pudo guardar el manifiesto.'
}

$logPath = Join-Path $PSScriptRoot "log_creauto_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
try {
    $log = @()
    if ($log.Count -gt 0) {
        $log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
    }
} catch { }

Write-Host ''
Write-LabOk 'Creación automática finalizada.'
Write-LabInfo 'Las vulnerabilidades se aplican desde menu.ps1 [5] Crear vulnerabilidad.'