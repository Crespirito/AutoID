<#
.SYNOPSIS
    Creación manual de entorno de laboratorio en Entra ID.
.DESCRIPTION
    Construcción interactiva de un escenario a medida. El menú se genera
    dinámicamente a partir de las capacidades disponibles (filtradas por
    nivel y TestDisponible).

    Funcionalidades:
      - Añadir objetos de cualquier capacidad disponible.
      - Borrar objetos locales (sin tocar el tenant).
      - Listar el estado actual del escenario.
      - Guardar el manifiesto y finalizar.
      - Exportar el escenario construido como JSON reutilizable.
      - Cargar un escenario existente para ampliarlo.

    CONTRASEÑAS:
    Para cada usuario, el operador puede introducir la contraseña manualmente
    o generarla desde la semilla de la sesión manual. En ningún caso se
    guarda la contraseña en el manifiesto ni en el JSON exportado.

<<<<<<< Updated upstream
=======
    DOMINIO DEL TENANT:
    (Get-MgContext).TenantId devuelve el GUID del tenant, NO el dominio DNS.
    Usarlo como sufijo de UPN provoca 'The domain portion of the
    userPrincipalName property is invalid'. Por eso el contexto se construye
    con Get-LabTenantDomainResuelto (Get-MgDomain -> Get-MgOrganization).

>>>>>>> Stashed changes
    La sesión de Graph la gestiona menu.ps1. Este script NO conecta ni
    desconecta; solo verifica que hay sesión activa.
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
param()

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

# ============================================================
# VERIFICACIÓN DE SESIÓN
# ============================================================
if (-not (Test-LabGraphSession)) {
    Write-LabError 'No hay sesión de Graph activa. Ejecuta este script desde menu.ps1.'
    exit 1
}

# ============================================================
# ESTADO Y CONFIGURACIÓN
# ============================================================
$config = Get-LabConfig
$nivel = Get-LabNivelActual -Config $config
if ($nivel) { $config['NivelLicencia'] = $nivel }
$null = Initialize-LabCapacidades -Root (Join-Path $PSScriptRoot 'lib_caps')

# ============================================================
<<<<<<< Updated upstream
# SEMILLA DE LA SESIÓN MANUAL
# ============================================================

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
=======
# DOMINIO DEL TENANT
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

# ============================================================
# SEMILLA DE LA SESIÓN MANUAL
# ============================================================

# Get-LabSecretsDir / Get-LabSeed / New-LabPasswordFromSeed viven en lib_helpers.ps1
>>>>>>> Stashed changes

# ============================================================
# CARGA O CREACIÓN DE ESCENARIO
# ============================================================

function Select-LabEscenarioInicial {
    <#
    .SYNOPSIS
        Pregunta al operador si quiere cargar un escenario existente o empezar de cero.
    .OUTPUTS
        PSCustomObject normalizado (nuevo o cargado).
    #>
    Show-LabHeader -Titulo 'CREACION MANUAL - INICIO'

    Write-Host '  [1] Empezar de cero'
    Write-Host '  [2] Cargar un escenario existente'
    Write-Host ''

    $op = Read-Host 'Selecciona una opción'

    if ($op -eq '2') {
        $escenarios = Get-LabEscenariosDisponibles
        if ($escenarios.Count -eq 0) {
            Write-LabWarn 'No hay escenarios disponibles. Se empieza de cero.'
           return (ConvertTo-LabEscenarioNormalizado -Raw ([pscustomobject]@{ nombre = $null }))
        }

        Write-Host ''
        Write-Host '  Escenarios disponibles:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $escenarios.Count; $i++) {
            Write-Host ('    [{0}] {1}' -f $i, $escenarios[$i])
        }
        $sel = Read-Host 'Selecciona un escenario'
        if ($sel -match '^\d+$' -and [int]$sel -lt $escenarios.Count) {
            $path = Join-Path (Get-LabEscenariosPath) "$($escenarios[[int]$sel]).json"
            return (ConvertTo-LabEscenarioNormalizado -Path $path)
        }
    }

    return (ConvertTo-LabEscenarioNormalizado -Raw ([pscustomobject]@{}))
}

# ============================================================
# MENÚ GENERADO DESDE CAPACIDADES
# ============================================================

function Show-LabMenuCapacidades {
    <#
    .SYNOPSIS
        Muestra las capacidades disponibles y devuelve la seleccionada.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Nivel,
        [Parameter(Mandatory = $true)] [hashtable]$Contexto
    )

    $capacidades = Get-LabCapacidades -Nivel $Nivel -SoloDisponibles -Contexto $Contexto
    if ($capacidades.Count -eq 0) {
        Write-LabWarn 'No hay capacidades disponibles para el nivel actual.'
        return $null
    }

    Show-LabHeader -Titulo 'CREACION MANUAL - AÑADIR OBJETOS'

    for ($i = 0; $i -lt $capacidades.Count; $i++) {
        $cap = $capacidades[$i]
        $nombre = if ($cap.ContainsKey('Descripcion') -and $cap.Descripcion) { $cap.Descripcion } else { $cap.Nombre }
        Write-Host ('  [{0}] {1}' -f $i, $nombre)
    }
    Write-Host ''

    $sel = Read-Host 'Selecciona una capacidad (Enter para volver)'
    if ([string]::IsNullOrWhiteSpace($sel)) { return $null }
    if (-not ($sel -match '^\d+$') -or [int]$sel -ge $capacidades.Count) {
        Write-LabWarn 'Selección inválida.'
        return $null
    }
    return $capacidades[[int]$sel]
}

# ============================================================
# ESTADO Y BORRADO LOCAL
# ============================================================

function Show-LabEstadoEscenario {
    <#
    .SYNOPSIS
        Muestra el estado actual del escenario en construcción.
    #>
    param(
        [Parameter(Mandatory = $true)] [object]$Escenario
    )

    Show-LabHeader -Titulo 'ESTADO DEL ESCENARIO'

    $total = 0
    foreach ($nombreCap in $Escenario.Secciones.Keys) {
        $def = @($Escenario.Secciones[$nombreCap])
        if ($def.Count -eq 0) { continue }
        $cap = Get-LabCapacidad -Nombre $nombreCap
        $nombreVisible = if ($cap -and $cap.ContainsKey('Descripcion') -and $cap.Descripcion) { $cap.Descripcion } else { $nombreCap }
        Write-Host "  ${nombreVisible}: $($def.Count)" -ForegroundColor Cyan
        $total += $def.Count
    }

    if ($total -eq 0) {
        Write-Host '  (escenario vacío)' -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Invoke-BorrarObjetoLocal {
    <#
    .SYNOPSIS
        Borra un objeto del escenario en construcción (solo local).
    #>
    param(
        [Parameter(Mandatory = $true)] [object]$Escenario
    )

    Show-LabHeader -Titulo 'BORRAR OBJETO LOCAL'

    $seccionesConDef = @()
    foreach ($nombreCap in $Escenario.Secciones.Keys) {
        $def = @($Escenario.Secciones[$nombreCap])
        if ($def.Count -gt 0) {
            $seccionesConDef += [pscustomobject]@{ NombreCap = $nombreCap; Def = $def }
        }
    }

    if ($seccionesConDef.Count -eq 0) {
        Write-LabWarn 'El escenario está vacío.'
        return
    }

    for ($i = 0; $i -lt $seccionesConDef.Count; $i++) {
        $s = $seccionesConDef[$i]
        Write-Host ('  [{0}] {1} ({2} objetos)' -f $i, $s.NombreCap, $s.Def.Count)
    }
    Write-Host ''

    $sel = Read-Host 'Selecciona una sección (Enter para cancelar)'
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    if (-not ($sel -match '^\d+$') -or [int]$sel -ge $seccionesConDef.Count) {
        Write-LabWarn 'Selección inválida.'
        return
    }

    $seccion = $seccionesConDef[[int]$sel]
    for ($j = 0; $j -lt $seccion.Def.Count; $j++) {
        $o = $seccion.Def[$j]
        $desc = $o | ConvertTo-Json -Compress
        Write-Host ('    [{0}] {1}' -f $j, $desc)
    }
    $selObj = Read-Host 'Selecciona el objeto a borrar (Enter para cancelar)'
    if ([string]::IsNullOrWhiteSpace($selObj)) { return }
    if (-not ($selObj -match '^\d+$') -or [int]$selObj -ge $seccion.Def.Count) {
        Write-LabWarn 'Selección inválida.'
        return
    }

    $nuevaLista = @()
    for ($k = 0; $k -lt $seccion.Def.Count; $k++) {
        if ($k -ne [int]$selObj) { $nuevaLista += $seccion.Def[$k] }
    }
    $Escenario.Secciones[$seccion.NombreCap] = $nuevaLista
    Write-LabOk "Objeto borrado del escenario local. Nota: si ya se creó en el tenant, no se borra; solo se excluye del manifiesto."
}

# ============================================================
# FLUJO PRINCIPAL
# ============================================================

# 1. Cargar o empezar de cero
$esc = Select-LabEscenarioInicial

# Comprobar si tiene nombre sin que StrictMode se queje
$tieneNombre = $false
<<<<<<< Updated upstream
if ($esc.PSObject.Properties['Nombre'] -and -not [string]::IsNullOrWhiteSpace($esc.Nombre)) {
=======
if ((Get-LabPropiedadValor -Objeto $esc -Nombre 'Nombre') -and -not [string]::IsNullOrWhiteSpace($esc.Nombre)) {
>>>>>>> Stashed changes
    $tieneNombre = $true
}

if (-not $tieneNombre) {
    $nombreAuto = 'manual_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
    $esc | Add-Member -NotePropertyName 'Nombre' -NotePropertyValue $nombreAuto -Force
}
# 2. Semilla de la sesión manual
$nombreSemilla = 'manual_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
$semilla = Get-LabSeed -NombreEscenario $nombreSemilla
Write-LabInfo "Semilla de esta sesión: $nombreSemilla"
Write-LabInfo 'Conserva esta semilla para reproducir las contraseñas generadas automáticamente.'
Write-Host ''

<<<<<<< Updated upstream
# 3. Contexto para PreguntarUI y TestDisponible
$ctx = @{
    TenantId        = (Get-MgContext).TenantId
    TenantDomain    = (Get-MgContext).TenantId
=======
# 3. Resolver dominio del tenant
#
# (Get-MgContext).TenantId devuelve el GUID del tenant, NO un dominio DNS.
# Usarlo como sufijo de UPN provocaba:
#   [Request_BadRequest] The domain portion of the userPrincipalName
#   property is invalid. You must use one of the verified domain names...
# Por eso el contexto se construye con el dominio verificado resuelto.
$tenantDomain = Get-LabTenantDomainResuelto
if ([string]::IsNullOrWhiteSpace($tenantDomain)) {
    Write-LabError 'No se pudo resolver el dominio verificado del tenant.'
    Write-LabInfo 'Comprueba que la sesión de Graph tiene permiso para leer dominios (Domain.Read.All) u organización (Organization.Read.All).'
    exit 1
}
Write-LabInfo "Dominio del tenant resuelto: $tenantDomain"

# 4. Contexto para PreguntarUI y TestDisponible
$ctx = @{
    TenantId        = (Get-MgContext).TenantId
    TenantDomain    = $tenantDomain
>>>>>>> Stashed changes
    Nivel           = $nivel
    Manifiesto      = $null
    ObjetosCreados  = @{}
    Config          = $config
    SnapshotPreLab  = @{}
    PasswordsPorUpn = @{}
    DerivarPassword = {
        param($upn)
        return (New-LabPasswordFromSeed -Semilla $semilla -Upn $upn)
    }.GetNewClosure()
    Semilla         = $semilla
}

# 5. Bucle de construcción
$salir = $false
while (-not $salir) {
    Show-LabHeader -Titulo 'CREACION MANUAL - CONSTRUCCION DEL ESCENARIO'
    Show-LabEstadoEscenario -Escenario $esc

    Write-Host '  --- Añadir ---' -ForegroundColor Cyan
    Write-Host '  [A] Añadir objeto (menú generado desde capacidades)'
    Write-Host ''
    Write-Host '  --- Gestionar ---' -ForegroundColor Cyan
    Write-Host '  [L] Listar detalle'
    Write-Host '  [B] Borrar objeto local'
    Write-Host ''
    Write-Host '  --- Finalizar ---' -ForegroundColor Cyan
    Write-Host '  [G] Guardar manifiesto y finalizar'
    Write-Host '  [X] Exportar escenario como JSON'
    Write-Host '  [S] Salir sin guardar'
    Write-Host ''

    $op = Read-Host 'Selecciona una opción'

    switch ($op.ToUpper()) {
        'A' {
            $cap = Show-LabMenuCapacidades -Nivel $nivel -Contexto $ctx
            if ($cap) {
                try {
                    $def = & $cap.PreguntarUI $ctx
                    if ($null -ne $def) {
                        if (-not $esc.Secciones.ContainsKey($cap.Nombre)) {
                            $esc.Secciones[$cap.Nombre] = @()
                        }
                        $esc.Secciones[$cap.Nombre] += $def
                        Write-LabOk "Objeto añadido a '$($cap.Nombre)'."
                    }
                } catch {
                    Write-LabError "Error en PreguntarUI de '$($cap.Nombre)': $($_.Exception.Message)"
                }
            }
            Wait-LabKey
        }
        'L' {
            Show-LabEstadoEscenario -Escenario $esc
            foreach ($nombreCap in $esc.Secciones.Keys) {
                $def = @($esc.Secciones[$nombreCap])
                if ($def.Count -eq 0) { continue }
                Write-Host "  ${nombreCap}:" -ForegroundColor Cyan
                foreach ($d in $def) {
                    Write-Host "    - $($d | ConvertTo-Json -Compress)" -ForegroundColor Gray
                }
            }
            Wait-LabKey
        }
        'B' {
            Invoke-BorrarObjetoLocal -Escenario $esc
            Wait-LabKey
        }
        'G' {
            if (Read-LabConfirm '¿Guardar manifiesto y finalizar la creación manual?') {
                $salir = $true
            }
        }
        'X' {
            $nombreExport = Read-Host 'Nombre del escenario a exportar (sin extensión)'
            if (-not [string]::IsNullOrWhiteSpace($nombreExport)) {
                $path = Join-Path (Get-LabEscenariosPath) "$nombreExport.json"
                try {
                    $obj = ConvertFrom-LabEscenarioNormalizado -EscenarioNormalizado $esc
                    $obj | ConvertTo-Json -Depth 15 | Set-Content -Path $path -Encoding UTF8 -Force
                    Write-LabOk "Escenario exportado: $path"
                } catch {
                    Write-LabError "No se pudo exportar: $($_.Exception.Message)"
                }
            }
            Wait-LabKey
        }
        'S' {
            if (Read-LabConfirm '¿Salir sin guardar el manifiesto? Los objetos creados quedarán sin registrar para cleanup.') {
                $salir = $true
                $esc = $null
            }
        }
        default {
            Write-LabWarn 'Opción no válida.'
            Start-Sleep -Seconds 1
        }
    }
}

<<<<<<< Updated upstream
# 5. Si se guardó, crear y guardar manifiesto
if ($null -ne $esc) {
    $manifiesto = New-LabManifiestoVacio -Escenario $esc.Nombre -Nivel $nivel -Semilla $nombreSemilla
    $manifiesto.TenantDomain = (Get-MgContext).TenantId
=======
# 6. Si se guardó, crear y guardar manifiesto
if ($null -ne $esc) {
    # Garantizar dominio resuelto (por si cambió el tenant o el contexto
    # original no lo tenía). El escenario normalizado no lleva TenantDomain
    # por sí mismo; lo inyectamos en el manifiesto.
    if ([string]::IsNullOrWhiteSpace($tenantDomain)) {
        $tenantDomain = Get-LabTenantDomainResuelto
    }
    if ([string]::IsNullOrWhiteSpace($tenantDomain)) {
        Write-LabError 'No se pudo resolver el dominio verificado del tenant. Abortando guardado de manifiesto.'
        exit 1
    }

    $manifiesto = New-LabManifiestoVacio -Escenario $esc.Nombre -Nivel $nivel -Semilla $nombreSemilla
    $manifiesto.TenantDomain = $tenantDomain

    # El contexto de creación debe llevar el dominio resuelto. Se refresca
    # por si acaso (el bucle pudo construirse con un $tenantDomain distinto).
    $ctx.TenantDomain = $tenantDomain
>>>>>>> Stashed changes

    $resultado = Invoke-LabCreacion -EscenarioNormalizado $esc -Manifiesto $manifiesto -Config $config

    $manifiestoPath = Get-LabManifiestoPath
    if (Save-LabManifiesto -Manifiesto $manifiesto -Path $manifiestoPath) {
        Write-LabOk "Manifiesto guardado: $manifiestoPath"
    } else {
        Write-LabError 'No se pudo guardar el manifiesto.'
    }

    if ($ctx.PasswordsPorUpn.Count -gt 0) {
        Write-Host ''
        Write-Host '=== CONTRASEÑAS DERIVADAS (MOSTRAR UNA SOLA VEZ) ===' -ForegroundColor Yellow
        Write-Host 'Anota estas credenciales. No se guardan en el manifiesto ni en el JSON.' -ForegroundColor Yellow
        Write-Host "Semilla de esta sesión: $nombreSemilla" -ForegroundColor Yellow
        Write-Host ''
        foreach ($upn in $ctx.PasswordsPorUpn.Keys) {
            Write-Host ("  {0} / {1}" -f $upn, $ctx.PasswordsPorUpn[$upn]) -ForegroundColor Gray
        }
        Write-Host ''
    }
}

Write-Host ''
Write-LabOk 'Creación manual finalizada.'