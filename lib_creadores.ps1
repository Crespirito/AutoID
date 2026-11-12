<#
.SYNOPSIS
    Motor de orquestación de creación y reversión (PowerShell 7).
.DESCRIPTION
    Proporciona:
      - Invoke-LabCreacion: crea objetos respetando las dependencias de Entra ID.
      - Invoke-LabReversion: revierte vulnerabilidades y objetos de forma segura.
      - Snapshot pre-lab: detecta objetos que ya existían antes del laboratorio.
      - Verificación de identidad (red de seguridad) ampliada a todos los
        tipos de objeto y vulnerabilidad que el sistema puede manifestar.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

# ============================================================
# UTILIDADES INTERNAS
# ============================================================

function Get-LabContextoBase {
    param(
        [object]$Manifiesto,
        [hashtable]$Config,
        [hashtable]$SnapshotPreLab = $null
    )

    $passwords = @{}
    if ($Config -and $Config.Contains('Passwords') -and $null -ne $Config['Passwords']) {
        $passwords = $Config['Passwords']
    }

    $tenantDomain = $null
    if ($Manifiesto.PSObject.Properties['tenantDomain']) {
        $tenantDomain = $Manifiesto.tenantDomain
    }

    return @{
        TenantDomain    = $tenantDomain
        Nivel           = Get-LabNivelActual -Config $Config
        Manifiesto      = $Manifiesto
        ObjetosCreados  = @{}
        Config          = $Config
        SnapshotPreLab  = if ($SnapshotPreLab) { $SnapshotPreLab } else { @{} }
        PasswordsPorUpn = $passwords
    }
}

function New-LabSnapshotPreLab {
    $snapshot = @{
        usuarios     = @{}
        grupos       = @{}
        aplicaciones = @{}
    }

    try {
        $usuarios = Get-MgUser -All -Property 'id,userPrincipalName' -ErrorAction SilentlyContinue
        foreach ($u in $usuarios) {
            if ($u.userPrincipalName) { $snapshot.usuarios[$u.userPrincipalName.ToLowerInvariant()] = $u.Id }
        }
    } catch { }

    try {
        $grupos = Get-MgGroup -All -Property 'id,displayName' -ErrorAction SilentlyContinue
        foreach ($g in $grupos) {
            if ($g.displayName) { $snapshot.grupos[$g.displayName] = $g.Id }
        }
    } catch { }

    try {
        $apps = Get-MgApplication -All -Property 'id,displayName' -ErrorAction SilentlyContinue
        foreach ($a in $apps) {
            if ($a.displayName) { $snapshot.aplicaciones[$a.displayName] = $a.Id }
        }
    } catch { }

    return $snapshot
}

function Add-LabObjetoAlManifiesto {
    param(
        [object]$Manifiesto,
        [string]$Capacidad,
        [object]$ObjetoCreado
    )

    $id = 'obj-{0:D4}' -f ($Manifiesto.objetos.Count + 1)

    $tipo = 'Desconocido'
    if ($ObjetoCreado.PSObject.Properties['tipo']) { $tipo = $ObjetoCreado.tipo }

    $estado = 'creado'
    if ($ObjetoCreado.PSObject.Properties['estadoDetalle']) { $estado = $ObjetoCreado.estadoDetalle }

    $datos = @{}
    foreach ($p in $ObjetoCreado.PSObject.Properties) {
        if ($p.Name -notin @('tipo','estadoDetalle')) {
            $datos[$p.Name] = $p.Value
        }
    }

    $envuelto = [pscustomobject]@{
        id        = $id
        tipo      = $tipo
        capacidad = $Capacidad
        estado    = $estado
        timestamp = (Get-Date).ToString('o')
        tenantId  = (Get-MgContext).TenantId
        datos     = $datos
    }

    $Manifiesto.objetos += $envuelto
    return $envuelto
}

# ============================================================
# CREACIÓN
# ============================================================

function Invoke-LabCreacion {
    param(
        [object]$EscenarioNormalizado,
        [object]$Manifiesto,
        [hashtable]$Config
    )

    Write-LabInfo 'Construyendo snapshot pre-lab...'
    $snapshot = New-LabSnapshotPreLab
    $ctx = Get-LabContextoBase -Manifiesto $Manifiesto -Config $Config -SnapshotPreLab $snapshot

    # ORDEN ESTRICTO DE ENTRA ID
    $ordenCapacidades = @(
        'Usuarios',
        'Grupos',
        'Aplicaciones',
        'Relaciones',
        'AppRoles',
        'CredencialesApp',
        'PermisosApi',
        'Invitados',
        'Licencias',
        'MetodosAuth',
        'AccesoCondicional',
        'GruposDinamicos',
        'GruposRoleAssignable',
        'AdministrativeUnits',
        'Pim'
    )

    foreach ($nombreCap in $ordenCapacidades) {
        # Secciones es un OrderedDictionary: no tiene ContainsKey, se usa Contains().
        if (-not $EscenarioNormalizado.Secciones.Contains($nombreCap)) { continue }
        $def = @($EscenarioNormalizado.Secciones[$nombreCap])
        if ($def.Count -eq 0) { continue }

        $cap = Get-LabCapacidad -Nombre $nombreCap
        if (-not $cap) { continue }

        Write-LabInfo "Creando: $nombreCap ($($def.Count) objetos)..."

        try {
            $creados = & $cap.Crear $def $ctx
            $lista = @()

            foreach ($o in @($creados)) {
                if ($null -eq $o) { continue }
                $envuelto = Add-LabObjetoAlManifiesto -Manifiesto $Manifiesto -Capacidad $nombreCap -ObjetoCreado $o
                $lista += $envuelto
            }

            $ctx.ObjetosCreados[$nombreCap] = $lista

            if ($cap.ContainsKey('PostCrear') -and $cap.PostCrear -is [scriptblock]) {
                try { & $cap.PostCrear $lista $ctx } catch {
                    Write-LabWarn "PostCrear de '$nombreCap' falló: $($_.Exception.Message)"
                }
            }
        } catch {
            Write-LabError "Error creando '$nombreCap': $($_.Exception.Message)"
        }
    }
}

# ============================================================
# REVERSIÓN
# ============================================================

function Invoke-LabReversion {
    param(
        [object]$Manifiesto,
        [hashtable]$Config,
        [switch]$Forzar
    )

    $ctx = Get-LabContextoBase -Manifiesto $Manifiesto -Config $Config
    $contadores = @{ Revertidos = 0; Fallidos = 0; Omitidos = 0; Preexistentes = 0 }

    # 1. Vulnerabilidades primero
    foreach ($v in @($Manifiesto.vulnerabilidades)) {
        if ($v.estado -in @('preexistente','revertida','no-revertida','omitida')) {
            if ($v.estado -eq 'preexistente') { $contadores.Preexistentes++ }
            continue
        }

        $cap = Get-LabCapacidad -Nombre $v.capacidad
        if (-not $cap) {
            Write-LabWarn "Capacidad '$($v.capacidad)' no disponible; no se puede revertir $($v.id)."
            $v.estado = 'no-revertida'
            $contadores.Omitidos++
            continue
        }

        if (-not $v.PSObject.Properties['datos'] -or $null -eq $v.datos) {
            Write-LabWarn "Vulnerabilidad $($v.id) sin 'datos'."
            $v.estado = 'no-revertida'
            $contadores.Omitidos++
            continue
        }

        if (-not (Test-LabVulnerabilidadCoincideConManifiesto -Vulnerabilidad $v)) {
            Write-LabWarn "La vulnerabilidad $($v.id) no coincide con el objeto afectado. Se omite."
            $v.estado = 'no-revertida'
            $contadores.Omitidos++
            continue
        }

        if ($cap.ContainsKey('PreRevertir') -and $cap.PreRevertir -is [scriptblock]) {
            try { & $cap.PreRevertir @($v) $ctx } catch {
                Write-LabWarn "PreRevertir falló para $($v.id): $($_.Exception.Message)"
            }
        }

        try {
            $ok = & $cap.Revertir $v $ctx
            if ($ok) { $v.estado = 'revertida'; $contadores.Revertidos++ }
            else      { $v.estado = 'fallida';   $contadores.Fallidos++ }
        } catch {
            Write-LabWarn "Error revirtiendo $($v.id): $($_.Exception.Message)"
            $v.estado = 'fallida'
            $contadores.Fallidos++
        }
    }

    # 2. Objetos en LIFO (Inverso al orden de creación)
    $ordenados = @($Manifiesto.objetos | Sort-Object { $_.timestamp } -Descending)
    foreach ($o in $ordenados) {
        if ($o.estado -in @('preexistente','revertido','no-revertido','omitido')) {
            if ($o.estado -eq 'preexistente') { $contadores.Preexistentes++ }
            continue
        }

        $cap = Get-LabCapacidad -Nombre $o.capacidad
        if (-not $cap) {
            if ($Forzar) {
                $ok = Invoke-LabBorradoGenerico -Objeto $o
                if ($ok) { $o.estado = 'revertido'; $contadores.Revertidos++ }
                else      { $o.estado = 'no-revertido'; $contadores.Omitidos++ }
            } else {
                Write-LabWarn "Capacidad '$($o.capacidad)' no disponible; $($o.id) queda en el manifiesto."
                $o.estado = 'no-revertido'
                $contadores.Omitidos++
            }
            continue
        }

        if (-not (Test-LabObjetoCoincideConManifiesto -Objeto $o)) {
            Write-LabWarn "El objeto $($o.id) tiene un objectId distinto. Se omite."
            $o.estado = 'no-revertido'
            $contadores.Omitidos++
            continue
        }

        if ($cap.ContainsKey('PreRevertir') -and $cap.PreRevertir -is [scriptblock]) {
            try { & $cap.PreRevertir @($o) $ctx } catch {
                Write-LabWarn "PreRevertir falló para $($o.id): $($_.Exception.Message)"
            }
        }

        try {
            $ok = & $cap.Revertir $o $ctx
            if ($ok) { $o.estado = 'revertido'; $contadores.Revertidos++ }
            else      { $o.estado = 'fallido';   $contadores.Fallidos++ }
        } catch {
            Write-LabWarn "Error revirtiendo $($o.id): $($_.Exception.Message)"
            $o.estado = 'fallido'
            $contadores.Fallidos++
        }
    }

    return $contadores
}

# ============================================================
# VERIFICACIÓN DE IDENTIDAD (RED DE SEGURIDAD)
# ============================================================

function Get-LabDatoSeguro {
    <#
    .SYNOPSIS
        Devuelve el valor de un campo dentro de $Objeto.datos, o $null.
    #>
    param(
        [Parameter(Mandatory = $true)] [object]$Objeto,
        [Parameter(Mandatory = $true)] [string]$Nombre
    )

    if ($null -eq $Objeto -or $null -eq $Objeto.datos) { return $null }
    if ($Objeto.datos -is [hashtable]) {
        if ($Objeto.datos.Contains($Nombre)) { return $Objeto.datos[$Nombre] }
        return $null
    }
    if ($Objeto.datos.PSObject.Properties[$Nombre]) { return $Objeto.datos.$Nombre }
    return $null
}

function Test-LabCoincidenciaPorTipo {
    <#
    .SYNOPSIS
        Verifica el objectId del manifiesto contra el objeto real del tenant.
    .DESCRIPTION
        Devuelve $true si:
          - No hay objectId esperado (nada que verificar).
          - El objeto ya no existe (idempotente).
          - El objectId coincide.
        Devuelve $false si:
          - El objectId esperado existe en el manifiesto pero el objeto real
            tiene un objectId distinto.
        Para tipos sin objectId propio (asignaciones, relaciones), verifica
        el contenedor (app, SP, grupo, usuario, AU) si es posible.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Tipo,
        [Parameter(Mandatory = $true)] [object]$Datos,
        [string]$ObjectIdEsperado
    )

    # Helper de coincidencia sobre un objeto Graph
    $coincide = {
        param($Actual, $Esperado)
        if ($null -eq $Actual) { return $true }  # idempotente
        if ($Actual -is [array]) { $Actual = $Actual[0] }
        if ($null -eq $Actual) { return $true }
        if ([string]::IsNullOrWhiteSpace($Esperado)) { return $true }
        return ($Actual.Id -eq $Esperado)
    }

    try {
        switch ($Tipo) {
            'Usuario' {
                $upn = $null
                if ($Datos -is [hashtable]) { $upn = $Datos['upn'] } elseif ($Datos.PSObject.Properties['upn']) { $upn = $Datos.upn }
                if ([string]::IsNullOrWhiteSpace($upn)) { return $true }
                $actual = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
                return (& $coincide $actual $ObjectIdEsperado)
            }
            'Grupo' {
                $dn = $null
                if ($Datos -is [hashtable]) { $dn = $Datos['displayName'] } elseif ($Datos.PSObject.Properties['displayName']) { $dn = $Datos.displayName }
                if ([string]::IsNullOrWhiteSpace($dn)) { return $true }
                $actual = Get-MgGroup -Filter "displayName eq '$($dn -replace "'","''")'" -ErrorAction SilentlyContinue
                return (& $coincide $actual $ObjectIdEsperado)
            }
            'GrupoDinamico' {
                $dn = $null
                if ($Datos -is [hashtable]) { $dn = $Datos['displayName'] } elseif ($Datos.PSObject.Properties['displayName']) { $dn = $Datos.displayName }
                if ([string]::IsNullOrWhiteSpace($dn)) { return $true }
                $actual = Get-MgGroup -Filter "displayName eq '$($dn -replace "'","''")'" -ErrorAction SilentlyContinue
                return (& $coincide $actual $ObjectIdEsperado)
            }
            'GrupoRoleAssignable' {
                $dn = $null
                if ($Datos -is [hashtable]) { $dn = $Datos['displayName'] } elseif ($Datos.PSObject.Properties['displayName']) { $dn = $Datos.displayName }
                if ([string]::IsNullOrWhiteSpace($dn)) { return $true }
                $actual = Get-MgGroup -Filter "displayName eq '$($dn -replace "'","''")'" -ErrorAction SilentlyContinue
                return (& $coincide $actual $ObjectIdEsperado)
            }
            'Aplicacion' {
                $dn = $null
                if ($Datos -is [hashtable]) { $dn = $Datos['displayName'] } elseif ($Datos.PSObject.Properties['displayName']) { $dn = $Datos.displayName }
                if ([string]::IsNullOrWhiteSpace($dn)) { return $true }
                $actual = Get-MgApplication -Filter "displayName eq '$($dn -replace "'","''")'" -ErrorAction SilentlyContinue
                return (& $coincide $actual $ObjectIdEsperado)
            }
            'ServicePrincipal' {
                if ([string]::IsNullOrWhiteSpace($ObjectIdEsperado)) { return $true }
                $actual = Get-MgServicePrincipal -ServicePrincipalId $ObjectIdEsperado -ErrorAction SilentlyContinue
                return (& $coincide $actual $ObjectIdEsperado)
            }
            'AdministrativeUnit' {
                if ([string]::IsNullOrWhiteSpace($ObjectIdEsperado)) { return $true }
                $actual = Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $ObjectIdEsperado -ErrorAction SilentlyContinue
                return (& $coincide $actual $ObjectIdEsperado)
            }
            'Invitado' {
                if ([string]::IsNullOrWhiteSpace($ObjectIdEsperado)) { return $true }
                $actual = Get-MgUser -UserId $ObjectIdEsperado -ErrorAction SilentlyContinue
                return (& $coincide $actual $ObjectIdEsperado)
            }
            'AccesoCondicional' {
                if ([string]::IsNullOrWhiteSpace($ObjectIdEsperado)) { return $true }
                $actual = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $ObjectIdEsperado -ErrorAction SilentlyContinue
                return (& $coincide $actual $ObjectIdEsperado)
            }
            'CredencialApp' {
                # Verificamos la app contenedora (keyId de la credencial vive dentro)
                $appId = $null
                if ($Datos -is [hashtable]) { $appId = $Datos['appId'] } elseif ($Datos.PSObject.Properties['appId']) { $appId = $Datos.appId }
                if ([string]::IsNullOrWhiteSpace($appId)) { return $true }
                $actual = Get-MgApplication -Filter "appId eq '$($appId -replace "'","''")'" -ErrorAction SilentlyContinue
                if ($null -eq $actual) { return $true }
                if ($actual -is [array]) { $actual = $actual[0] }
                return ($null -ne $actual)
            }
            'AppRole' {
                $appId = $null
                if ($Datos -is [hashtable]) { $appId = $Datos['appId'] } elseif ($Datos.PSObject.Properties['appId']) { $appId = $Datos.appId }
                if ([string]::IsNullOrWhiteSpace($appId)) { return $true }
                $actual = Get-MgApplication -Filter "appId eq '$($appId -replace "'","''")'" -ErrorAction SilentlyContinue
                if ($null -eq $actual) { return $true }
                if ($actual -is [array]) { $actual = $actual[0] }
                return ($null -ne $actual)
            }
            'AppRoleAssignment' {
                $spId = $null
                if ($Datos -is [hashtable]) { $spId = $Datos['servicePrincipalId'] } elseif ($Datos.PSObject.Properties['servicePrincipalId']) { $spId = $Datos.servicePrincipalId }
                if ([string]::IsNullOrWhiteSpace($spId)) { return $true }
                $actual = Get-MgServicePrincipal -ServicePrincipalId $spId -ErrorAction SilentlyContinue
                return ($null -ne $actual)
            }
            'PermisoApi' {
                $spId = $null
                if ($Datos -is [hashtable]) { $spId = $Datos['clientSpId'] } elseif ($Datos.PSObject.Properties['clientSpId']) { $spId = $Datos.clientSpId }
                if ([string]::IsNullOrWhiteSpace($spId)) { return $true }
                $actual = Get-MgServicePrincipal -ServicePrincipalId $spId -ErrorAction SilentlyContinue
                return ($null -ne $actual)
            }
            'Licencia' {
                $userId = $null
                if ($Datos -is [hashtable]) { $userId = $Datos['userId'] } elseif ($Datos.PSObject.Properties['userId']) { $userId = $Datos.userId }
                if ([string]::IsNullOrWhiteSpace($userId)) { return $true }
                $actual = Get-MgUser -UserId $userId -ErrorAction SilentlyContinue
                return ($null -ne $actual)
            }
            'MetodoAuth' {
                $userId = $null
                if ($Datos -is [hashtable]) { $userId = $Datos['userId'] } elseif ($Datos.PSObject.Properties['userId']) { $userId = $Datos.userId }
                if ([string]::IsNullOrWhiteSpace($userId)) { return $true }
                $actual = Get-MgUser -UserId $userId -ErrorAction SilentlyContinue
                return ($null -ne $actual)
            }
            'PimEligibleRole' {
                $userId = $null
                if ($Datos -is [hashtable]) { $userId = $Datos['userId'] } elseif ($Datos.PSObject.Properties['userId']) { $userId = $Datos.userId }
                if ([string]::IsNullOrWhiteSpace($userId)) { return $true }
                $actual = Get-MgUser -UserId $userId -ErrorAction SilentlyContinue
                return ($null -ne $actual)
            }
            'MembresiaGrupo' {
                $groupId = $null
                if ($Datos -is [hashtable]) { $groupId = $Datos['groupId'] } elseif ($Datos.PSObject.Properties['groupId']) { $groupId = $Datos.groupId }
                if ([string]::IsNullOrWhiteSpace($groupId)) { return $true }
                $actual = Get-MgGroup -GroupId $groupId -ErrorAction SilentlyContinue
                return ($null -ne $actual)
            }
            'AdministrativeUnitMember' {
                $auId = $null
                if ($Datos -is [hashtable]) { $auId = $Datos['administrativeUnitId'] } elseif ($Datos.PSObject.Properties['administrativeUnitId']) { $auId = $Datos.administrativeUnitId }
                if ([string]::IsNullOrWhiteSpace($auId)) { return $true }
                $actual = Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $auId -ErrorAction SilentlyContinue
                return ($null -ne $actual)
            }
            'AdministrativeUnitRole' {
                $auId = $null
                if ($Datos -is [hashtable]) { $auId = $Datos['administrativeUnitId'] } elseif ($Datos.PSObject.Properties['administrativeUnitId']) { $auId = $Datos.administrativeUnitId }
                if ([string]::IsNullOrWhiteSpace($auId)) { return $true }
                $actual = Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $auId -ErrorAction SilentlyContinue
                return ($null -ne $actual)
            }
            default {
                # Tipo no verificable: delegamos al Revertir de la capacidad.
                Write-LabInfo "Test-LabCoincidenciaPorTipo: tipo '$Tipo' sin verificación de contenedor. Se delega al Revertir de la capacidad."
                return $true
            }
        }
    } catch {
        Write-LabWarn "Error verificando coincidencia de '$Tipo': $($_.Exception.Message). Se asume coincidencia."
        return $true
    }
}

function Test-LabObjetoCoincideConManifiesto {
    param([object]$Objeto)

    if ($null -eq $Objeto) { return $true }

    $objectIdEsperado = $null
    if ($Objeto.datos) {
        if ($Objeto.datos -is [hashtable]) {
            if ($Objeto.datos.Contains('objectId')) { $objectIdEsperado = $Objeto.datos['objectId'] }
        } elseif ($Objeto.datos.PSObject.Properties['objectId']) {
            $objectIdEsperado = $Objeto.datos.objectId
        }
    }

    $tipo = 'Desconocido'
    if ($Objeto.PSObject.Properties['tipo'] -and $Objeto.tipo) { $tipo = $Objeto.tipo }

    return (Test-LabCoincidenciaPorTipo -Tipo $tipo -Datos $Objeto.datos -ObjectIdEsperado $objectIdEsperado)
}

function Test-LabVulnerabilidadCoincideConManifiesto {
    param([object]$Vulnerabilidad)

    $datos = $Vulnerabilidad.datos
    if ($null -eq $datos) { return $true }

    $objectIdEsperado = $null
    if ($datos -is [hashtable]) {
        if ($datos.Contains('objetoAfectadoObjectId')) { $objectIdEsperado = $datos['objetoAfectadoObjectId'] }
    } elseif ($datos.PSObject.Properties['objetoAfectadoObjectId']) {
        $objectIdEsperado = $datos.objetoAfectadoObjectId
    }

    if ([string]::IsNullOrWhiteSpace($objectIdEsperado)) { return $true }

    try {
        $actual = $null
        switch ($Vulnerabilidad.tipo) {
            'ServicePrincipalOwner' { $actual = Get-MgServicePrincipal -ServicePrincipalId $objectIdEsperado -ErrorAction SilentlyContinue }
            'GroupOwner'            { $actual = Get-MgGroup -GroupId $objectIdEsperado -ErrorAction SilentlyContinue }
            'ApplicationSecret'     { $actual = Get-MgApplication -ApplicationId $objectIdEsperado -ErrorAction SilentlyContinue }
            'PimEligibleRole'       { $actual = Get-MgUser -UserId $objectIdEsperado -ErrorAction SilentlyContinue }
            default {
                Write-LabInfo "Test-LabVulnerabilidadCoincideConManifiesto: tipo '$($Vulnerabilidad.tipo)' sin verificación. Se asume coincidencia."
                return $true
            }
        }

        if ($actual -is [array]) { $actual = $actual[0] }
        if ($null -eq $actual) { return $true }
        if ($actual.Id -ne $objectIdEsperado) { return $false }
        return $true
    } catch {
        return $true
    }
}

function Invoke-LabBorradoGenerico {
    param([object]$Objeto)
    try {
        switch ($Objeto.tipo) {
            'Usuario'          { if ($Objeto.datos.upn) { $null = Remove-MgUser -UserId $Objeto.datos.upn -Confirm:$false -ErrorAction Stop }; return $true }
            'Grupo'            { if ($Objeto.datos.objectId) { $null = Remove-MgGroup -GroupId $Objeto.datos.objectId -Confirm:$false -ErrorAction Stop }; return $true }
            'Aplicacion'       { if ($Objeto.datos.objectId) { $null = Remove-MgApplication -ApplicationId $Objeto.datos.objectId -Confirm:$false -ErrorAction Stop }; return $true }
            'ServicePrincipal' { if ($Objeto.datos.objectId) { $null = Remove-MgServicePrincipal -ServicePrincipalId $Objeto.datos.objectId -Confirm:$false -ErrorAction Stop }; return $true }
            default { return $false }
        }
    } catch { return $false }
}