<#
.SYNOPSIS
    Librería de orquestación de creación, validación y reversión.
.DESCRIPTION
    Proporciona:
      - Invoke-LabValidacionEscenario: valida el escenario normalizado
        llamando a ValidarDef de cada capacidad.
      - Invoke-LabCreacion: crea los objetos del escenario normalizado
        llamando a Crear de cada capacidad, registrando en el manifiesto.
        NO procesa vulnerabilidades: viven fuera del escenario y se
        aplican desde el flujo dedicado de menu.ps1.
      - Invoke-LabReversion: revierte vulnerabilidades primero (con
        verificación de objectId y PreRevertir) y objetos después, en
        orden inverso de creación (LIFO).

    El núcleo no conoce tipos concretos: itera por secciones del
    escenario normalizado (clave = Nombre de capacidad) y despacha
    a la capacidad correspondiente.

    SEPARACIÓN ESCENARIO / VULNERABILIDADES:
      - Escenario: objetos que se crean desde cero (usuarios, grupos,
        apps, AUs, PIM...). Viven en $Manifiesto.objetos.
      - Vulnerabilidades: modificaciones maliciosas aplicadas SOBRE
        objetos existentes. Viven en $Manifiesto.vulnerabilidades.
        No son una sección del escenario. Se aplican desde menu.ps1
        ([5] Crear vulnerabilidad) y se revierten desde clean_up.ps1.

    SEGURIDAD DE OBJETOS PREEXISTENTES:
    1. Antes de crear, Invoke-LabCreacion construye (o recibe) un snapshot
       pre-lab con los identificadores que ya existían en el tenant antes
       del laboratorio. Lo pasa en $Contexto.SnapshotPreLab.
    2. Antes de revertir, Invoke-LabReversion verifica que el objectId del
       manifiesto coincide con el actual, tanto para objetos como para
       vulnerabilidades.
    3. Antes de revertir una vulnerabilidad, se llama a PreRevertir de la
       capacidad si existe (por ejemplo, para desactivar una asignación
       PIM activa antes de cancelar la solicitud elegible).
.NOTES
    Depende de lib_ui.ps1, lib_caps.ps1, lib_manifiesto.ps1, lib_niveles.ps1.
    Se carga por dot-sourcing desde menu.ps1.
#>

# ============================================================
# UTILIDADES INTERNAS
# ============================================================

function Get-LabContextoBase {
    <#
    .SYNOPSIS
        Construye el contexto compartido que se pasa a las capacidades.
    .PARAMETER Manifiesto
        Manifiesto en construcción (referencia, se muta fuera).
    .PARAMETER Config
        Configuración actual.
    .PARAMETER SnapshotPreLab
        Hashtable con identificadores preexistentes (opcional).
    .PARAMETER Log
        Lista de log compartida.
    .OUTPUTS
        Hashtable con el contexto.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifiesto,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $false)]
        [hashtable]$SnapshotPreLab = $null,

        [Parameter(Mandatory = $false)]
        [object]$Log = $null
    )

    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    $nivel = Get-LabNivelActual -Config $Config
    $nivelEfectivo = Get-LabNivelEfectivo -Config $Config

    return @{
        TenantId       = if ($ctx) { $ctx.TenantId } else { $null }
        TenantDomain   = $Manifiesto.tenantDomain
        Nivel          = $nivel              # configurado (compat)
        NivelEfectivo  = $nivelEfectivo      # min(config, tenant)
        Manifiesto     = $Manifiesto
        ObjetosCreados = @{}
        Config         = $Config
        SnapshotPreLab = if ($SnapshotPreLab) { $SnapshotPreLab } else { @{} }
        Log            = $Log
    }
}

function New-LabSnapshotPreLab {
    <#
    .SYNOPSIS
        Construye un snapshot de los objetos que ya existen en el tenant.
    .DESCRIPTION
        Consulta usuarios, grupos y aplicaciones actuales y devuelve un
        hashtable con tres claves: 'usuarios' (UPNs), 'grupos' (displayNames)
        y 'aplicaciones' (displayNames). Las capacidades consultan este
        snapshot para no adoptar objetos preexistentes.

        NOTA SOBRE VULNERABILIDADES: las vulnerabilidades no dependen del
        snapshot. Dependen del objeto afectado (que puede ser preexistente
        o no). La capacidad cap_vulnerabilidades.ps1 decide por su cuenta
        si el objeto afectado es preexistente consultando el snapshot.
    .OUTPUTS
        Hashtable con 'usuarios', 'grupos', 'aplicaciones'.
    #>
    $snapshot = @{
        usuarios     = @{}
        grupos       = @{}
        aplicaciones = @{}
    }

    try {
        $usuarios = Get-MgUser -All -Property 'id,userPrincipalName' -ErrorAction SilentlyContinue
        foreach ($u in @($usuarios)) {
            if ($u.userPrincipalName) {
                $snapshot.usuarios[$u.userPrincipalName.ToLowerInvariant()] = $u.Id
            }
        }
    } catch {
        Write-LabWarn "No se pudo construir el snapshot de usuarios: $($_.Exception.Message)"
    }

    try {
        $grupos = Get-MgGroup -All -Property 'id,displayName' -ErrorAction SilentlyContinue
        foreach ($g in @($grupos)) {
            if ($g.displayName) {
                $snapshot.grupos[$g.displayName] = $g.Id
            }
        }
    } catch {
        Write-LabWarn "No se pudo construir el snapshot de grupos: $($_.Exception.Message)"
    }

    try {
        $apps = Get-MgApplication -All -Property 'id,displayName' -ErrorAction SilentlyContinue
        foreach ($a in @($apps)) {
            if ($a.displayName) {
                $snapshot.aplicaciones[$a.displayName] = $a.Id
            }
        }
    } catch {
        Write-LabWarn "No se pudo construir el snapshot de aplicaciones: $($_.Exception.Message)"
    }

    return $snapshot
}

function Add-LabObjetoAlManifiesto {
    <#
    .SYNOPSIS
        Añade un objeto devuelto por Crear al manifiesto, con los campos comunes.
    .DESCRIPTION
        El campo 'estado' se toma de 'estadoDetalle' si está presente en el
        objeto creado ('creado', 'reutilizado', 'preexistente'). Si no,
        se usa el valor por defecto ('creado').

        Esta función SOLO se usa para objetos del escenario. Las
        vulnerabilidades se registran con Add-LabManifiestoVulnerabilidad.
    .PARAMETER Manifiesto
        Manifiesto en construcción.
    .PARAMETER Capacidad
        Nombre de la capacidad que creó el objeto.
    .PARAMETER ObjetoCreado
        Objeto devuelto por Crear (con al menos 'tipo' y datos específicos).
    .PARAMETER Estado
        Estado por defecto si el objeto no trae 'estadoDetalle'.
    .OUTPUTS
        El objeto envuelto, ya añadido al manifiesto.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifiesto,

        [Parameter(Mandatory = $true)]
        [string]$Capacidad,

        [Parameter(Mandatory = $true)]
        [object]$ObjetoCreado,

        [string]$Estado = 'creado'
    )

    $id = 'obj-{0:D4}' -f ($Manifiesto.objetos.Count + 1)
    $ctx = Get-MgContext -ErrorAction SilentlyContinue

    $tipo = if ($ObjetoCreado.PSObject.Properties['tipo']) { $ObjetoCreado.tipo } else { 'Desconocido' }

    # Estado: prioridad a estadoDetalle del objeto creado
    $estadoFinal = $Estado
    if ($ObjetoCreado.PSObject.Properties['estadoDetalle'] -and
        -not [string]::IsNullOrWhiteSpace($ObjetoCreado.estadoDetalle)) {
        $estadoFinal = $ObjetoCreado.estadoDetalle
    }

    # Extraer datos: todo excepto 'tipo' y 'estadoDetalle'
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
        estado    = $estadoFinal
        timestamp = (Get-Date).ToString('o')
        tenantId  = if ($ctx) { $ctx.TenantId } else { $null }
        datos     = $datos
    }

    $Manifiesto.objetos += $envuelto
    return $envuelto
}

# ============================================================
# VALIDACIÓN
# ============================================================

function Invoke-LabValidacionEscenario {
    <#
    .SYNOPSIS
        Valida un escenario normalizado llamando a ValidarDef de cada capacidad.
    .DESCRIPTION
        Las vulnerabilidades NO son una sección del escenario, así que no
        pasan por aquí. Su validación la hace cap_vulnerabilidades.ValidarDef
        desde el flujo de creación de vulnerabilidades de menu.ps1.
    .PARAMETER EscenarioNormalizado
        Resultado de ConvertTo-LabEscenarioNormalizado.
    .PARAMETER Contexto
        Contexto compartido (de Get-LabContextoBase).
    .OUTPUTS
        Array de strings con los errores. Vacío si es válido.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$EscenarioNormalizado,

        [Parameter(Mandatory = $false)]
        [hashtable]$Contexto = @{}
    )

    $errores = @()

    foreach ($nombreCap in $EscenarioNormalizado.Secciones.Keys) {
        $def = @($EscenarioNormalizado.Secciones[$nombreCap])
        if ($def.Count -eq 0) { continue }

        $cap = Get-LabCapacidad -Nombre $nombreCap
        if (-not $cap) {
            $errores += "Capacidad '$nombreCap' no registrada (¿carpeta desactivada?). La sección '$nombreCap' no se puede procesar."
            continue
        }

        $nivelActual = if ($Contexto.ContainsKey('Nivel')) { $Contexto.Nivel } else { 'Free' }
        if (-not (Test-LabNivelPermitido -NivelCapacidad $cap.Nivel -NivelConfigurado $nivelActual)) {
            $errores += "Capacidad '$nombreCap' requiere nivel $($cap.Nivel), pero el nivel actual es $nivelActual."
            continue
        }

        try {
            $errsCap = & $cap.ValidarDef $def
            foreach ($e in @($errsCap)) {
                if (-not [string]::IsNullOrWhiteSpace($e)) {
                    $errores += "[$nombreCap] $e"
                }
            }
        } catch {
            $errores += "[$nombreCap] Error en ValidarDef: $($_.Exception.Message)"
        }
    }

    return $errores
}

# ============================================================
# CREACIÓN
# ============================================================

function Invoke-LabCreacion {
    <#
    .SYNOPSIS
        Crea los objetos del escenario normalizado llamando a Crear de cada capacidad.
    .DESCRIPTION
        Itera por las capacidades en orden de dependencia (topológico),
        y para cada una con sección no vacía, llama a su Crear. Los
        objetos devueltos se envuelven y se añaden al manifiesto.

        IMPORTANTE: las vulnerabilidades NO se procesan aquí. No son una
        sección del escenario. Se aplican desde menu.ps1 con el flujo
        dedicado y se registran con Add-LabManifiestoVulnerabilidad.

        Salvaguarda: si una capacidad llamada 'Vulnerabilidades' tuviera
        una sección en el escenario (por compatibilidad con manifiestos
        antiguos), se omite con aviso. No debe procesarse como escenario.

        Antes de crear, construye (o recibe) un snapshot pre-lab y lo pasa
        en $Contexto.SnapshotPreLab.
    .PARAMETER EscenarioNormalizado
        Resultado de ConvertTo-LabEscenarioNormalizado.
    .PARAMETER Manifiesto
        Manifiesto en construcción (se muta).
    .PARAMETER Config
        Configuración actual.
    .PARAMETER SnapshotPreLab
        Snapshot pre-lab ya construido. Si no se pasa, se construye.
    .PARAMETER Log
        Lista de log compartida.
    .PARAMETER Detener
        Scriptblock opcional que se evalúa antes de cada capacidad. Si
        devuelve $true, se detiene la creación.
    .OUTPUTS
        Hashtable con Resultado ('completado' o 'detenido'), Contexto y CapacidadDetenida.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$EscenarioNormalizado,

        [Parameter(Mandatory = $true)]
        [object]$Manifiesto,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $false)]
        [hashtable]$SnapshotPreLab = $null,

        [Parameter(Mandatory = $false)]
        [object]$Log = $null,

        [Parameter(Mandatory = $false)]
        [scriptblock]$Detener = $null
    )

    # Construir snapshot si no se pasó
    if (-not $SnapshotPreLab) {
        Write-LabInfo 'Construyendo snapshot pre-lab...'
        $SnapshotPreLab = New-LabSnapshotPreLab
    }

    $ctx = Get-LabContextoBase -Manifiesto $Manifiesto -Config $Config -SnapshotPreLab $SnapshotPreLab -Log $Log

    $orden = Get-LabOrdenCapacidades -EscenarioNormalizado $EscenarioNormalizado

    foreach ($nombreCap in $orden) {
        # Salvaguarda: vulnerabilidades no se procesan como escenario
        if ($nombreCap -eq 'Vulnerabilidades') {
            Write-LabWarn "La capacidad 'Vulnerabilidades' no se procesa como parte del escenario. Usa el flujo [5] Crear vulnerabilidad de menu.ps1."
            continue
        }

        if ($Detener) {
            if (& $Detener $nombreCap $ctx) {
                return @{ Resultado = 'detenido'; Contexto = $ctx; CapacidadDetenida = $nombreCap }
            }
        }

        $def = @($EscenarioNormalizado.Secciones[$nombreCap])
        if ($def.Count -eq 0) { continue }

        $cap = Get-LabCapacidad -Nombre $nombreCap
        if (-not $cap) {
            Write-LabWarn "Capacidad '$nombreCap' no registrada; se omite."
            continue
        }

        Write-LabInfo "Creando: $nombreCap ($($def.Count) objetos)"

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
                try {
                    & $cap.PostCrear $lista $ctx
                } catch {
                    Write-LabWarn "PostCrear de '$nombreCap' falló: $($_.Exception.Message)"
                }
            }
        } catch {
            Write-LabError "Error creando '$nombreCap': $($_.Exception.Message)"
        }
    }

    return @{ Resultado = 'completado'; Contexto = $ctx; CapacidadDetenida = $null }
}

function Get-LabOrdenCapacidades {
    <#
    .SYNOPSIS
        Devuelve el orden topológico de las capacidades con sección no vacía.
    .OUTPUTS
        Array de nombres de capacidad en orden de ejecución.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$EscenarioNormalizado
    )

    $conDef = @($EscenarioNormalizado.Secciones.Keys | Where-Object {
        @($EscenarioNormalizado.Secciones[$_]).Count -gt 0
    })

    if ($conDef.Count -eq 0) { return @() }

    $script:LabOrdenTemp = @()
    $visitados = @{}
    $enProceso = @{}

    function Resolve-LabCap {
        param($nombre)
        if ($visitados.ContainsKey($nombre)) { return }
        if ($enProceso.ContainsKey($nombre)) {
            Write-LabWarn "Ciclo detectado en dependencias de '$nombre'. Se ignora."
            return
        }
        $enProceso[$nombre] = $true

        $cap = Get-LabCapacidad -Nombre $nombre
        if ($cap) {
            foreach ($dep in @($cap.DependeDe)) {
                if ($conDef -contains $dep) {
                    Resolve-LabCap -nombre $dep
                }
            }
        }

        $enProceso.Remove($nombre)
        $visitados[$nombre] = $true
        $script:LabOrdenTemp += $nombre
    }

    foreach ($n in $conDef) {
        Resolve-LabCap -nombre $n
    }
    return $script:LabOrdenTemp
}

# ============================================================
# REVERSIÓN
# ============================================================

function Invoke-LabReversion {
    <#
    .SYNOPSIS
        Revierte vulnerabilidades y objetos del manifiesto.
    .DESCRIPTION
        Orden de borrado:
          1. Vulnerabilidades (lista aparte), primero.
             - Verifica objectId del objeto afectado si está en datos.
             - Llama a PreRevertir de la capacidad si existe.
             - Llama a Revertir de la capacidad.
             - Estados: aplicada -> revertida, o fallida / no-revertida.
          2. Objetos, en orden inverso de creación (LIFO).
             - Verifica objectId.
             - Llama a PreRevertir de la capacidad si existe.
             - Llama a Revertir.

        Estados ignorados:
          - Vulnerabilidades: preexistente, revertida, no-revertida, omitida.
          - Objetos: preexistente, revertido, no-revertido, omitido.
    .PARAMETER Manifiesto
        Manifiesto cargado (se muta).
    .PARAMETER Config
        Configuración actual.
    .PARAMETER Log
        Lista de log compartida.
    .PARAMETER Forzar
        Si se especifica, para objetos cuya capacidad no está registrada,
        intenta un borrado genérico por tipo.
    .OUTPUTS
        Hashtable con contadores: Revertidos, Fallidos, Omitidos, Preexistentes.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifiesto,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $false)]
        [object]$Log = $null,

        [switch]$Forzar
    )

    $ctx = Get-LabContextoBase -Manifiesto $Manifiesto -Config $Config -Log $Log
    $contadores = @{ Revertidos = 0; Fallidos = 0; Omitidos = 0; Preexistentes = 0 }

    # --------------------------------------------------------
    # 1. Vulnerabilidades primero
    # --------------------------------------------------------
    foreach ($v in @($Manifiesto.vulnerabilidades)) {
        # Estados ignorados
        if ($v.estado -in $script:LabEstadosIgnoradosVulnerabilidad) {
            if ($v.estado -eq 'preexistente') { $contadores.Preexistentes++ }
            continue
        }
        if ($v.estado -notin $script:LabEstadosReversiblesVulnerabilidad) { continue }

        $cap = Get-LabCapacidad -Nombre $v.capacidad
        if (-not $cap) {
            Write-LabWarn "Capacidad '$($v.capacidad)' no disponible; no se puede revertir $($v.id)."
            $v.estado = 'no-revertida'
            $contadores.Omitidos++
            continue
        }

        # Validar datos
        if (-not $v.PSObject.Properties['datos'] -or $null -eq $v.datos) {
            Write-LabWarn "Vulnerabilidad $($v.id) sin 'datos' en el manifiesto. No se puede revertir."
            $v.estado = 'no-revertida'
            $contadores.Omitidos++
            continue
        }

        # Verificar objectId del objeto afectado
        if (-not (Test-LabVulnerabilidadCoincideConManifiesto -Vulnerabilidad $v)) {
            Write-LabWarn "La vulnerabilidad $($v.id) (tipo '$($v.tipo)') no coincide con el objeto afectado actual (objectId distinto o ya no existe). Se omite la reversión."
            $v.estado = 'no-revertida'
            $contadores.Omitidos++
            continue
        }

        # PreRevertir si existe
        if ($cap.ContainsKey('PreRevertir') -and $cap.PreRevertir -is [scriptblock]) {
            try {
                $null = & $cap.PreRevertir @($v) $ctx
            } catch {
                Write-LabWarn "PreRevertir de '$($v.capacidad)' falló para $($v.id): $($_.Exception.Message)"
            }
        }

        try {
            $ok = & $cap.Revertir $v $ctx
            if ($ok) {
                $v.estado = 'revertida'
                $contadores.Revertidos++
            } else {
                $v.estado = 'fallida'
                $contadores.Fallidos++
            }
        } catch {
            Write-LabWarn "Error revirtiendo $($v.id): $($_.Exception.Message)"
            $v.estado = 'fallida'
            $contadores.Fallidos++
        }
    }

    # --------------------------------------------------------
    # 2. Objetos en orden inverso de creación (LIFO)
    # --------------------------------------------------------
    $ordenados = @($Manifiesto.objetos | Sort-Object { $_.timestamp } -Descending)
    foreach ($o in $ordenados) {
        # Estados ignorados
        if ($o.estado -in $script:LabEstadosIgnoradosObjeto) {
            if ($o.estado -eq 'preexistente') { $contadores.Preexistentes++ }
            continue
        }
        if ($o.estado -notin $script:LabEstadosReversiblesObjeto) { continue }

        $cap = Get-LabCapacidad -Nombre $o.capacidad
        if (-not $cap) {
            if ($Forzar) {
                $ok = Invoke-LabBorradoGenerico -Objeto $o
                if ($ok) {
                    $o.estado = 'revertido'
                    $contadores.Revertidos++
                } else {
                    $o.estado = 'no-revertido'
                    $contadores.Omitidos++
                }
            } else {
                Write-LabWarn "Capacidad '$($o.capacidad)' no disponible; $($o.id) queda en el manifiesto."
                $o.estado = 'no-revertido'
                $contadores.Omitidos++
            }
            continue
        }

        # Verificar objectId
        if (-not (Test-LabObjetoCoincideConManifiesto -Objeto $o)) {
            Write-LabWarn "El objeto $($o.id) (tipo '$($o.tipo)') no coincide con el del manifiesto (objectId distinto o ya no existe). Se omite el borrado."
            $o.estado = 'no-revertido'
            $contadores.Omitidos++
            continue
        }

        # PreRevertir si existe
        if ($cap.ContainsKey('PreRevertir') -and $cap.PreRevertir -is [scriptblock]) {
            try {
                $null = & $cap.PreRevertir @($o) $ctx
            } catch {
                Write-LabWarn "PreRevertir de '$($o.capacidad)' falló para $($o.id): $($_.Exception.Message)"
            }
        }

        try {
            $ok = & $cap.Revertir $o $ctx
            if ($ok) {
                $o.estado = 'revertido'
                $contadores.Revertidos++
            } else {
                $o.estado = 'fallido'
                $contadores.Fallidos++
            }
        } catch {
            Write-LabWarn "Error revirtiendo $($o.id): $($_.Exception.Message)"
            $o.estado = 'fallido'
            $contadores.Fallidos++
        }
    }

    return $contadores
}

function Test-LabObjetoCoincideConManifiesto {
    <#
    .SYNOPSIS
        Comprueba que el objeto actual coincide con el objectId del manifiesto.
    .DESCRIPTION
        Tipos con verificación específica:
          - Usuario (por upn)
          - Grupo (por displayName)
          - Aplicacion (por displayName)
          - ServicePrincipal (por objectId)
          - AdministrativoUnit (por displayName)

        Para tipos sin verificación específica, se devuelve $true (se
        confía en el manifiesto). Es el comportamiento histórico, pero
        ahora los tipos más comunes tienen verificación.

        Si el manifiesto no tiene objectId, no se puede verificar; se
        devuelve $true (idempotente).
        Si el objeto ya no existe, se devuelve $true (idempotente).
        Si el objectId actual difiere del del manifiesto, se devuelve $false.
    .OUTPUTS
        $true si se puede borrar, $false si no.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Objeto
    )

    $objectIdEsperado = $null
    if ($Objeto.datos -and $Objeto.datos.PSObject.Properties['objectId']) {
        $objectIdEsperado = $Objeto.datos.objectId
    }
    if ([string]::IsNullOrWhiteSpace($objectIdEsperado)) {
        return $true
    }

    try {
        $actual = $null
        switch ($Objeto.tipo) {
            'Usuario' {
                if ($Objeto.datos.upn) {
                    $actual = Get-MgUser -UserId $Objeto.datos.upn -ErrorAction SilentlyContinue
                }
            }
            'Grupo' {
                if ($Objeto.datos.displayName) {
                    $actual = Get-MgGroup -Filter "displayName eq '$($Objeto.datos.displayName)'" -ErrorAction SilentlyContinue
                }
            }
            'Aplicacion' {
                if ($Objeto.datos.displayName) {
                    $actual = Get-MgApplication -Filter "displayName eq '$($Objeto.datos.displayName)'" -ErrorAction SilentlyContinue
                }
            }
            'ServicePrincipal' {
                $actual = Get-MgServicePrincipal -ServicePrincipalId $objectIdEsperado -ErrorAction SilentlyContinue
            }
            'AdministrativeUnit' {
                $actual = Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $objectIdEsperado -ErrorAction SilentlyContinue
            }
            default {
                # Tipo sin verificación genérica: confiamos en el manifiesto.
                return $true
            }
        }

        if ($actual -is [array]) { $actual = $actual[0] }
        if ($null -eq $actual) {
            # Ya no existe: idempotente, se puede "revertir" (no-op).
            return $true
        }
        if ($actual.Id -ne $objectIdEsperado) {
            # Existe otro objeto con el mismo nombre pero distinto Id.
            return $false
        }
        return $true
    } catch {
        # Si no se puede verificar, se confía en el manifiesto.
        return $true
    }
}

function Test-LabVulnerabilidadCoincideConManifiesto {
    <#
    .SYNOPSIS
        Comprueba que el objeto afectado por una vulnerabilidad sigue existiendo
        con el objectId esperado.
    .DESCRIPTION
        Cada tipo de vulnerabilidad guarda en datos el objectId del objeto
        afectado (además de otros identificadores específicos). Esta función
        usa ese objectId para verificar que el objeto no se ha borrado y
        recreado externamente.

        Si el manifiesto no tiene objectId del objeto afectado, no se puede
        verificar; se devuelve $true (idempotente, se confía en el manifiesto).
        Si el objeto ya no existe, se devuelve $true (idempotente, no hay
        nada que revertir en el objeto; la vulnerabilidad puede fallar al
        intentar deshacer, pero no se bloquea por eso).
        Si el objectId actual difiere del del manifiesto, se devuelve $false.

        TIPOS SOPORTADOS:
          - ServicePrincipalOwner: datos.objetoAfectadoObjectId (SP) o
            datos.servicePrincipalId
          - GroupOwner: datos.objetoAfectadoObjectId (grupo) o datos.groupId
          - ApplicationSecret: datos.objetoAfectadoObjectId (app) o
            datos.applicationId
          - PimEligibleRole: datos.objetoAfectadoObjectId (usuario) o
            datos.userId

        Para tipos no soportados, se devuelve $true.
    .PARAMETER Vulnerabilidad
        Entrada de $Manifiesto.vulnerabilidades.
    .OUTPUTS
        $true si se puede intentar revertir, $false si no.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vulnerabilidad
    )

    $datos = $Vulnerabilidad.datos
    if ($null -eq $datos) { return $true }

    # ObjectId del objeto afectado (preferido)
    $objectIdEsperado = $null
    if ($datos.PSObject.Properties['objetoAfectadoObjectId']) {
        $objectIdEsperado = $datos.objetoAfectadoObjectId
    }

    # Fallback por tipo (manifiestos antiguos o capacidades que no lo guardaron)
    if ([string]::IsNullOrWhiteSpace($objectIdEsperado)) {
        switch ($Vulnerabilidad.tipo) {
            'ServicePrincipalOwner' {
                if ($datos.PSObject.Properties['servicePrincipalId']) {
                    $objectIdEsperado = $datos.servicePrincipalId
                }
            }
            'GroupOwner' {
                if ($datos.PSObject.Properties['groupId']) {
                    $objectIdEsperado = $datos.groupId
                }
            }
            'ApplicationSecret' {
                if ($datos.PSObject.Properties['applicationId']) {
                    $objectIdEsperado = $datos.applicationId
                }
            }
            'PimEligibleRole' {
                if ($datos.PSObject.Properties['userId']) {
                    $objectIdEsperado = $datos.userId
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($objectIdEsperado)) {
        # Sin objectId: no podemos verificar; confiamos en el manifiesto.
        return $true
    }

    try {
        $actual = $null
        switch ($Vulnerabilidad.tipo) {
            'ServicePrincipalOwner' {
                $actual = Get-MgServicePrincipal -ServicePrincipalId $objectIdEsperado -ErrorAction SilentlyContinue
            }
            'GroupOwner' {
                $actual = Get-MgGroup -GroupId $objectIdEsperado -ErrorAction SilentlyContinue
            }
            'ApplicationSecret' {
                $actual = Get-MgApplication -ApplicationId $objectIdEsperado -ErrorAction SilentlyContinue
            }
            'PimEligibleRole' {
                $actual = Get-MgUser -UserId $objectIdEsperado -ErrorAction SilentlyContinue
            }
            default {
                return $true
            }
        }

        if ($actual -is [array]) { $actual = $actual[0] }
        if ($null -eq $actual) {
            # El objeto afectado ya no existe: idempotente.
            return $true
        }
        if ($actual.Id -ne $objectIdEsperado) {
            return $false
        }
        return $true
    } catch {
        return $true
    }
}

function Invoke-LabBorradoGenerico {
    <#
    .SYNOPSIS
        Intenta un borrado genérico por tipo, para objetos cuya capacidad no está.
    .OUTPUTS
        $true si se borró (o ya no existía), $false si no se pudo.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Objeto
    )

    try {
        switch ($Objeto.tipo) {
            'Usuario' {
                if ($Objeto.datos.upn) {
                    $null = Remove-MgUser -UserId $Objeto.datos.upn -Confirm:$false -ErrorAction Stop
                }
                return $true
            }
            'Grupo' {
                if ($Objeto.datos.objectId) {
                    $null = Remove-MgGroup -GroupId $Objeto.datos.objectId -Confirm:$false -ErrorAction Stop
                }
                return $true
            }
            'Aplicacion' {
                if ($Objeto.datos.objectId) {
                    $null = Remove-MgApplication -ApplicationId $Objeto.datos.objectId -Confirm:$false -ErrorAction Stop
                }
                return $true
            }
            'ServicePrincipal' {
                if ($Objeto.datos.objectId) {
                    $null = Remove-MgServicePrincipal -ServicePrincipalId $Objeto.datos.objectId -Confirm:$false -ErrorAction Stop
                }
                return $true
            }
            default {
                return $false
            }
        }
    } catch {
        return $false
    }
}