<#
.SYNOPSIS
    Librería de orquestación de creación, validación y reversión.
.DESCRIPTION
    Proporciona:
      - Invoke-LabValidacionEscenario: valida el escenario normalizado
        llamando a ValidarDef de cada capacidad.
      - Invoke-LabCreacion: crea los objetos del escenario normalizado
        llamando a Crear de cada capacidad, registrando en el manifiesto.
      - Invoke-LabReversion: revierte los objetos del manifiesto
        llamando a Revertir de cada capacidad.

    El núcleo no conoce tipos concretos: itera por secciones del
    escenario normalizado (clave = Nombre de capacidad) y despacha
    a la capacidad correspondiente.

    SEGURIDAD DE OBJETOS PREEXISTENTES:
    1. Antes de crear, Invoke-LabCreacion construye (o recibe) un snapshot
       pre-lab con los identificadores que ya existían en el tenant antes
       del laboratorio. Lo pasa en $Contexto.SnapshotPreLab. Las capacidades
       lo consultan para no adoptar objetos preexistentes.
    2. Antes de revertir, Invoke-LabReversion verifica que el objectId del
       manifiesto coincide con el actual. Si no coincide (objeto borrado y
       recreado), omite el borrado y avisa.
.NOTES
    Depende de lib_ui.ps1, lib_caps.ps1, lib_manifiesto.ps1.
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

    return @{
        TenantId       = if ($ctx) { $ctx.TenantId } else { $null }
        TenantDomain   = $Manifiesto.tenantDomain
        Nivel          = $nivel
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

        Antes de crear, construye (o recibe) un snapshot pre-lab y lo pasa
        en $Contexto.SnapshotPreLab. Las capacidades lo consultan para no
        adoptar objetos preexistentes.
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

    function Visit-LabCap {
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
                    Visit-LabCap -nombre $dep
                }
            }
        }

        $enProceso.Remove($nombre)
        $visitados[$nombre] = $true
        $script:LabOrdenTemp += $nombre
    }

    foreach ($n in $conDef) {
        Visit-LabCap -nombre $n
    }
    return $script:LabOrdenTemp
}

# ============================================================
# REVERSIÓN
# ============================================================

function Invoke-LabReversion {
    <#
    .SYNOPSIS
        Revierte los objetos del manifiesto llamando a Revertir de cada capacidad.
    .DESCRIPTION
        Orden de borrado:
          1. Vulnerabilidades (lista aparte), primero.
          2. Objetos, en orden inverso de creación (LIFO).

        Antes de borrar cada objeto, verifica que el objectId del manifiesto
        coincide con el actual. Si no coincide (objeto borrado y recreado
        externamente), omite el borrado y avisa.

        Estados ignorados: 'preexistente', 'revertido', 'no-revertido', 'omitido'.
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

    # 1. Vulnerabilidades primero
    foreach ($v in @($Manifiesto.vulnerabilidades)) {
        if ($v.estado -eq 'revertido') { continue }
        $cap = Get-LabCapacidad -Nombre $v.capacidad
        if (-not $cap) {
            Write-LabWarn "Capacidad '$($v.capacidad)' no disponible; no se puede revertir $($v.id)."
            $v.estado = 'no-revertido'
            $contadores.Omitidos++
            continue
        }
        try {
            $ok = & $cap.Revertir $v $ctx
            if ($ok) {
                $v.estado = 'revertido'
                $contadores.Revertidos++
            } else {
                $v.estado = 'fallido'
                $contadores.Fallidos++
            }
        } catch {
            Write-LabWarn "Error revirtiendo $($v.id): $($_.Exception.Message)"
            $v.estado = 'fallido'
            $contadores.Fallidos++
        }
    }

    # 2. Objetos en orden inverso de creación (LIFO)
    $ordenados = @($Manifiesto.objetos | Sort-Object { $_.timestamp } -Descending)
    foreach ($o in $ordenados) {
        # Estados que no se tocan
        if ($o.estado -in @('revertido','no-revertido','omitido','preexistente')) {
            if ($o.estado -eq 'preexistente') { $contadores.Preexistentes++ }
            continue
        }
        if ($o.estado -notin @('creado','reutilizado','fallido')) { continue }

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

        # --- VERIFICACIÓN DE objectId ---
        if (-not (Test-LabObjetoCoincideConManifiesto -Objeto $o)) {
            Write-LabWarn "El objeto $($o.id) (tipo '$($o.tipo)') no coincide con el del manifiesto (objectId distinto o ya no existe). Se omite el borrado."
            $o.estado = 'no-revertido'
            $contadores.Omitidos++
            continue
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
        Si el manifiesto no tiene objectId, no se puede verificar; se
        devuelve $true (se confía en el manifiesto).
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
        # Sin objectId en el manifiesto: no podemos verificar; confiamos.
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