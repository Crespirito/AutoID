<#
.SYNOPSIS
    Capacidad: Vulnerabilidades aplicadas sobre objetos existentes.
.DESCRIPTION
    Aplica vulnerabilidades (modificaciones maliciosas) sobre objetos que
    ya existen en el tenant. NO es una sección del escenario: las
    vulnerabilidades no se crean desde cero, se aplican sobre usuarios,
    grupos, apps o SPs existentes.

    FLUJO:
      1. menu.ps1 [5] Crear vulnerabilidad llama a PreguntarUI.
      2. PreguntarUI muestra los tipos disponibles agrupados por nivel
         (Free, P1, P2) y ofrece cargar del catálogo por nombre.
      3. Se parametriza (manual o catálogo con opción de sobrescribir) y
         se valida con ValidarDef.
      4. Se aplica con Crear.
      5. menu.ps1 registra el resultado con Add-LabManifiestoVulnerabilidad.
      6. clean_up.ps1 lo revierte llamando a PreRevertir (si existe) y
         Revertir.

    TIPOS SOPORTADOS (dispatch table en $script:VulnTipos):
      - ServicePrincipalOwner (Free): añade un usuario como owner de un SP.
      - GroupOwner (Free): añade un usuario como owner de un grupo.
      - ApplicationSecret (Free): añade un client secret a una app.
      - PimEligibleRole (P2): asigna un rol elegible PIM a un usuario.
        DELEGA en cap_pim.ps1 si está registrada. Si no, no se ofrece.

    NIVEL:
      - La capacidad base es Free.
      - Cada tipo declara su propio Nivel en $script:VulnTipos.
      - TestDisponible devuelve TiposDisponibles filtrados por NivelEfectivo
        (min entre configurado y real del tenant).
      - PreguntarUI muestra TODOS los tipos, pero los no disponibles
        aparecen deshabilitados con el motivo.

    CATÁLOGO:
      - escenarios/vulnerab/*.json contiene vulnerabilidades por nombre.
      - PreguntarUI [C] permite cargar una por nombre y, opcionalmente,
        sobrescribir sus parámetros.
      - Se filtra por nivel efectivo: los tipos no disponibles aparecen
        deshabilitados con el motivo.

    SEGURIDAD DE PREEXISTENTES:
      - Si el objeto afectado (SP, grupo, app, usuario) es preexistente
        (está en $Contexto.SnapshotPreLab), no se aplica la vulnerabilidad
        y se devuelve estadoDetalle = 'preexistente'.
      - Si el owner o el secreto ya existen, se marca 'reutilizado' y no
        se duplica.
      - Los secretos se muestran UNA SOLA VEZ en un bloque unificado.

    OBTENERCLAVES:
      - Devuelve las claves de los objetos afectados para que el snapshot
        pre-lab pueda construirse por capacidad.

    PREREVERTIR:
      - Para PimEligibleRole: cancela la RoleAssignmentScheduleRequest
        activa antes de que cap_pim.Revertir cancele la elegible. Sin
        esto, el rol queda activo tras el cleanup.

    DEPENDENCIAS:
      - ServicePrincipalOwner: Aplicaciones, Usuarios.
      - GroupOwner: Grupos, Usuarios.
      - ApplicationSecret: Aplicaciones.
      - PimEligibleRole: Usuarios (y cap_pim.ps1 registrada).

    NIVEL: Free (base). Los tipos P2 se ofrecen en runtime si el nivel
    efectivo lo permite.
#>

$Capacidad = @{
    Nombre      = 'Vulnerabilidades'
    Descripcion = 'Vulnerabilidades aplicadas sobre objetos existentes'
    SeccionJson = $null
    Alias       = @('vulnerabilidades','vulnerabilidad','vulnerability','vulns')
    Nivel       = 'Free'
    DependeDe   = @()
    PermisosApp = @('Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','Group.ReadWrite.All','User.Read.All','RoleManagement.ReadWrite.Directory')

    # ========================================================
    # TESTDISPONIBLE
    # ========================================================
    TestDisponible = {
        param($Contexto)

        if (-not (Test-LabGraphSession)) {
            return [pscustomobject]@{
                Disponible       = $false
                Motivo           = 'Sin sesión de Graph'
                TiposDisponibles = @()
            }
        }

        # Nivel efectivo: min(config, tenant)
        $nivelEfectivo = if ($Contexto -and $Contexto.ContainsKey('NivelEfectivo') -and $Contexto.NivelEfectivo) {
            $Contexto.NivelEfectivo
        } elseif ($Contexto -and $Contexto.ContainsKey('Config')) {
            Get-LabNivelEfectivo -Config $Contexto.Config
        } else {
            'Free'
        }

        $ordenEfectivo = Get-LabNivelOrden -Nivel $nivelEfectivo

        $tipos = @()
        foreach ($nombreTipo in $script:VulnTipos.Keys) {
            $meta = $script:VulnTipos[$nombreTipo]
            $ordenTipo = Get-LabNivelOrden -Nivel $meta.Nivel
            if ($ordenTipo -gt $ordenEfectivo) { continue }

            # PimEligibleRole requiere cap_pim.ps1 registrada
            if ($nombreTipo -eq 'PimEligibleRole' -and -not (Test-LabCapacidadRegistrada -Nombre 'Pim')) {
                continue
            }

            $tipos += $nombreTipo
        }

        $disponible = ($tipos.Count -gt 0)
        $motivo = if (-not $disponible) {
            "No hay tipos de vulnerabilidad disponibles para el nivel efectivo '$nivelEfectivo'."
        } else {
            $null
        }

        return [pscustomobject]@{
            Disponible       = $disponible
            Motivo           = $motivo
            TiposDisponibles = $tipos
        }
    }

    # ========================================================
    # VALIDARDEF
    # ========================================================
    ValidarDef = {
        param($Def)

        $errores = @()

        # Nivel efectivo
        $config = Get-LabConfig
        $nivelEfectivo = Get-LabNivelEfectivo -Config $config
        $ordenEfectivo = Get-LabNivelOrden -Nivel $nivelEfectivo

        $i = 0
        foreach ($v in @($Def)) {
            $i++
            if ($null -eq $v) {
                $errores += "Vulnerabilidad #$i es nula."
                continue
            }
            if ([string]::IsNullOrWhiteSpace($v.nombre)) {
                $errores += "Vulnerabilidad #$i sin 'nombre'."
            }
            if ([string]::IsNullOrWhiteSpace($v.tipo)) {
                $errores += "Vulnerabilidad #$i sin 'tipo'."
                continue
            }

            $meta = $script:VulnTipos[$v.tipo]
            if (-not $meta) {
                $errores += "Vulnerabilidad #$i con tipo no soportado: '$($v.tipo)'. Tipos válidos: $($script:VulnTipos.Keys -join ', ')."
                continue
            }

            # Nivel
            $ordenTipo = Get-LabNivelOrden -Nivel $meta.Nivel
            if ($ordenTipo -gt $ordenEfectivo) {
                $errores += "Vulnerabilidad #$i ('$($v.tipo)') requiere nivel $($meta.Nivel), pero el nivel efectivo es $nivelEfectivo."
                continue
            }

            # PimEligibleRole requiere cap_pim.ps1
            if ($v.tipo -eq 'PimEligibleRole' -and -not (Test-LabCapacidadRegistrada -Nombre 'Pim')) {
                $errores += "Vulnerabilidad #$i ('PimEligibleRole') requiere que cap_pim.ps1 esté registrada (carpeta p2 activa)."
                continue
            }

            # Validación específica del tipo
            try {
                $errsTipo = & $meta.Validar $v
                foreach ($e in @($errsTipo)) {
                    if (-not [string]::IsNullOrWhiteSpace($e)) {
                        $errores += "Vulnerabilidad #$i ('$($v.tipo)'): $e"
                    }
                }
            } catch {
                $errores += "Vulnerabilidad #$i ('$($v.tipo)'): error en validación: $($_.Exception.Message)"
            }
        }

        return $errores
    }

    # ========================================================
    # DESCRIBIR
    # ========================================================
    Describir = {
        param($Def)

        $lineas = @()
        foreach ($v in @($Def)) {
            if ($null -eq $v) { continue }
            $meta = $script:VulnTipos[$v.tipo]
            if ($meta) {
                $lineas += & $meta.Describir $v
            } else {
                $lineas += "$($v.nombre) ($($v.tipo) — desconocido)"
            }
        }
        return "Vulnerabilidades ($(@($Def).Count)): $($lineas -join '; ')"
    }

    # ========================================================
    # CREAR
    # ========================================================
    Crear = {
        param($Def, $Contexto)

        $creados = @()

        # Nivel efectivo
        $nivelEfectivo = if ($Contexto.ContainsKey('NivelEfectivo') -and $Contexto.NivelEfectivo) {
            $Contexto.NivelEfectivo
        } else {
            Get-LabNivelEfectivo -Config $Contexto.Config
        }
        $ordenEfectivo = Get-LabNivelOrden -Nivel $nivelEfectivo

        # Excluidas (por -ExcluirVulnerabilidad)
        $excluidas = if ($Contexto.ContainsKey('VulnerabilidadesExcluidas')) {
            @($Contexto.VulnerabilidadesExcluidas)
        } else {
            @()
        }

        # Acumulador de secretos para mostrar en bloque
        $secretosMostrados = @()

        foreach ($v in @($Def)) {
            if ($null -eq $v) { continue }

            # Exclusión
            if ($excluidas -contains '*' -or $excluidas -contains $v.nombre) {
                Write-LabInfo "Vulnerabilidad '$($v.nombre)' excluida por configuración."
                continue
            }

            $meta = $script:VulnTipos[$v.tipo]
            if (-not $meta) {
                Write-LabWarn "Tipo de vulnerabilidad no soportado: '$($v.tipo)'. Se omite."
                continue
            }

            # Nivel
            $ordenTipo = Get-LabNivelOrden -Nivel $meta.Nivel
            if ($ordenTipo -gt $ordenEfectivo) {
                Write-LabWarn "Vulnerabilidad '$($v.nombre)' requiere $($meta.Nivel), nivel efectivo es $nivelEfectivo. Se omite."
                continue
            }

            # PimEligibleRole: delegar en cap_pim.ps1
            if ($v.tipo -eq 'PimEligibleRole') {
                $capPim = Get-LabCapacidad -Nombre 'Pim'
                if (-not $capPim) {
                    Write-LabWarn "PimEligibleRole requiere cap_pim.ps1 (P2) y no está registrada. Se omite '$($v.nombre)'."
                    continue
                }

                # Adaptar a la forma que espera cap_pim.Crear
                $defPim = @([pscustomobject]@{
                    usuario       = $v.parametros.usuario
                    rol           = $v.parametros.rol
                    duracion      = if ($v.parametros.PSObject.Properties['duracion']) { $v.parametros.duracion } else { 'PT8H' }
                    justificacion = 'Asignación de laboratorio (vulnerabilidad)'
                })

                try {
                    $res = & $capPim.Crear $defPim $Contexto
                } catch {
                    Write-LabWarn "No se pudo aplicar PimEligibleRole '$($v.nombre)' vía cap_pim.ps1: $($_.Exception.Message)"
                    continue
                }

                foreach ($o in @($res)) {
                    if ($null -eq $o) { continue }
                    $estadoDetalle = if ($o.PSObject.Properties['estadoDetalle'] -and $o.estadoDetalle) { $o.estadoDetalle } else { 'creado' }

                    $datos = @{
                        capacidadAplicadora = 'Pim'
                        objetoAfectadoObjectId = if ($o.PSObject.Properties['userId']) { $o.userId } else { $null }
                        userId           = if ($o.PSObject.Properties['userId']) { $o.userId } else { $null }
                        roleDefinitionId = if ($o.PSObject.Properties['roleDefinitionId']) { $o.roleDefinitionId } else { $null }
                        scheduleRequestId = if ($o.PSObject.Properties['scheduleRequestId']) { $o.scheduleRequestId } else { $null }
                        upn              = if ($o.PSObject.Properties['upn']) { $o.upn } else { $null }
                        rol              = if ($o.PSObject.Properties['rol']) { $o.rol } else { $null }
                        tipoVulnerabilidad = 'PimEligibleRole'
                    }

                    $creados += [pscustomobject]@{
                        nombre            = $v.nombre
                        tipo              = 'PimEligibleRole'
                        capacidadAplicadora = 'Pim'
                        datos             = $datos
                        estadoDetalle     = $estadoDetalle
                    }
                }
                continue
            }

            # Tipos Free: aplicar directamente
            try {
                $res = & $meta.Aplicar $v $Contexto
            } catch {
                Write-LabWarn "No se pudo aplicar '$($v.nombre)' ($($v.tipo)): $($_.Exception.Message)"
                continue
            }

            if ($null -eq $res) { continue }

            $estadoDetalle = if ($res.PSObject.Properties['estadoDetalle'] -and $res.estadoDetalle) { $res.estadoDetalle } else { 'creado' }

            # Acumular secretos para bloque final
            if ($res.PSObject.Properties['secretoMostrar'] -and $res.secretoMostrar) {
                $secretosMostrados += $res.secretoMostrar
            }

            # Construir datos (sin secretoMostrar)
            $datos = @{
                capacidadAplicadora   = 'Vulnerabilidades'
                tipoVulnerabilidad    = $v.tipo
            }
            foreach ($p in $res.PSObject.Properties) {
                if ($p.Name -in @('tipo','estadoDetalle','secretoMostrar','tipoVulnerabilidad')) { continue }
                $datos[$p.Name] = $p.Value
            }

            $creados += [pscustomobject]@{
                nombre            = $v.nombre
                tipo              = $v.tipo
                capacidadAplicadora = 'Vulnerabilidades'
                datos             = $datos
                estadoDetalle     = $estadoDetalle
            }
        }

        # Mostrar secretos UNA SOLA VEZ en bloque
        if ($secretosMostrados.Count -gt 0) {
            Write-Host ''
            Write-Host '=== SECRETOS DE VULNERABILIDAD CREADOS (MOSTRAR UNA SOLA VEZ) ===' -ForegroundColor Yellow
            Write-Host 'Anota estos secretos. NO se guardan en el manifiesto ni se pueden recuperar.' -ForegroundColor Yellow
            Write-Host ''
            foreach ($s in $secretosMostrados) {
                Write-Host "  Vulnerabilidad : $($s.nombreVulnerabilidad)"
                Write-Host "  Aplicación     : $($s.aplicacion)"
                Write-Host "  DisplayName    : $($s.displayName)"
                Write-Host "  KeyId          : $($s.keyId)"
                Write-Host "  Secreto        : $($s.secreto)" -ForegroundColor Green
                Write-Host "  Expira         : $($s.expira)"
                Write-Host ''
            }
            Write-Host 'Si pierdes un secreto, tendrás que crear una vulnerabilidad nueva.' -ForegroundColor Yellow
            Write-Host ''
        }

        return $creados
    }

    # ========================================================
    # REVERTIR
    # ========================================================
    Revertir = {
        param($Objeto, $Contexto)

        if ($null -eq $Objeto) { return $false }
        if (-not $Objeto.PSObject.Properties['datos'] -or $null -eq $Objeto.datos) {
            Write-LabWarn "Vulnerabilidad sin 'datos': $($Objeto.id)"
            return $false
        }

        $tipo = if ($Objeto.PSObject.Properties['tipo']) { $Objeto.tipo } else { $null }
        if ([string]::IsNullOrWhiteSpace($tipo)) {
            if ($Objeto.datos.PSObject.Properties['tipoVulnerabilidad']) {
                $tipo = $Objeto.datos.tipoVulnerabilidad
            }
        }
        if ([string]::IsNullOrWhiteSpace($tipo)) {
            Write-LabWarn "Vulnerabilidad sin tipo identificable: $($Objeto.id)"
            return $false
        }

        $meta = $script:VulnTipos[$tipo]
        if (-not $meta) {
            Write-LabWarn "Tipo de vulnerabilidad no soportado para revertir: '$tipo'."
            return $false
        }

        # PimEligibleRole: delegar en cap_pim.Revertir
        if ($tipo -eq 'PimEligibleRole') {
            $capPim = Get-LabCapacidad -Nombre 'Pim'
            if (-not $capPim) {
                Write-LabWarn "PimEligibleRole requiere cap_pim.ps1 y no está registrada. No se puede revertir $($Objeto.id)."
                return $false
            }
            return (& $capPim.Revertir $Objeto $Contexto)
        }

        # Tipos Free: función auxiliar
        try {
            return (& $meta.Revertir $Objeto $Contexto)
        } catch {
            Write-LabWarn "No se pudo revertir '$($Objeto.id)' ($tipo): $($_.Exception.Message)"
            return $false
        }
    }

    # ========================================================
    # PREGUNTARUI
    # ========================================================
    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nueva vulnerabilidad'

        # Obtener tipos disponibles con estado
        $agrupados = Get-VulnTiposDisponiblesAgrupados -Contexto $Contexto

        if ($agrupados.TotalDisponibles -eq 0) {
            Write-LabWarn $agrupados.Motivo
            return $null
        }

        # Listado plano agrupado por nivel
        Write-Host "  Nivel efectivo: $($agrupados.NivelEfectivo)" -ForegroundColor Gray
        Write-Host ''

        $opciones = @()
        foreach ($nivel in @('Free','P1','P2')) {
            if (-not $agrupados.PorNivel.ContainsKey($nivel)) { continue }
            $items = @($agrupados.PorNivel[$nivel])
            if ($items.Count -eq 0) { continue }

            Write-Host "  --- $nivel ---" -ForegroundColor Cyan
            foreach ($item in $items) {
                if ($item.Disponible) {
                    $opciones += $item.Nombre
                    $idx = $opciones.Count
                    Write-Host ('    [{0}] {1}' -f $idx, $item.Nombre)
                } else {
                    Write-Host ('    [!] {0}  ({1})' -f $item.Nombre, $item.Motivo) -ForegroundColor DarkGray
                }
            }
            Write-Host ''
        }

        Write-Host '  Opciones:' -ForegroundColor Cyan
        Write-Host '    [número]  Elegir tipo y definir manualmente'
        Write-Host '    [C]       Cargar del catálogo por nombre'
        Write-Host '    [0]       Cancelar'
        Write-Host ''

        $sel = Read-Host '  Selecciona una opción'

        if ([string]::IsNullOrWhiteSpace($sel)) { return $null }

        if ($sel -match '^(?i)c$') {
            return (Read-VulnDesdeCatalogo -Contexto $Contexto)
        }

        if ($sel -eq '0') { return $null }

        if (-not ($sel -match '^\d+$') -or [int]$sel -lt 1 -or [int]$sel -gt $opciones.Count) {
            Write-LabWarn 'Selección inválida.'
            return $null
        }

        $tipo = $opciones[[int]$sel - 1]

        # Pedir nombre
        $nombre = Read-Host '  Nombre de la vulnerabilidad'
        if ([string]::IsNullOrWhiteSpace($nombre)) {
            Write-LabWarn 'Nombre vacío. Cancelando.'
            return $null
        }

        # Pedir parámetros
        $parametros = Read-VulnParametros -Tipo $tipo -Parametros @{}

        # Construir def
        $def = [pscustomobject]@{
            nombre     = $nombre
            tipo       = $tipo
            parametros = $parametros
        }

        # Validación local
        $meta = $script:VulnTipos[$tipo]
        $errs = & $meta.Validar $def
        if (@($errs).Count -gt 0) {
            Write-LabError 'La vulnerabilidad tiene errores de validación:'
            foreach ($e in @($errs)) { Write-Host "  - $e" -ForegroundColor Red }
            return $null
        }

        return $def
    }
}

# ============================================================
# DISPATCH TABLE: TIPOS DE VULNERABILIDAD
# ============================================================
$script:VulnTipos = @{

    'ServicePrincipalOwner' = @{
        Nivel     = 'Free'
        DependeDe = @('Aplicaciones','Usuarios')

        Validar = {
            param($v)
            $errores = @()
            if (-not $v.PSObject.Properties['parametros'] -or $null -eq $v.parametros) {
                $errores += "falta 'parametros'."
                return $errores
            }
            if ([string]::IsNullOrWhiteSpace($v.parametros.usuario)) {
                $errores += "falta 'parametros.usuario'."
            }
            if ([string]::IsNullOrWhiteSpace($v.parametros.aplicacion)) {
                $errores += "falta 'parametros.aplicacion'."
            }
            return $errores
        }

        Aplicar = {
            param($v, $Contexto)
            return (Invoke-VulnServicePrincipalOwner -Vulnerabilidad $v -Contexto $Contexto)
        }

        Revertir = {
            param($Objeto, $Contexto)
            return (Invoke-RevertirVulnServicePrincipalOwner -Objeto $Objeto)
        }

        Describir = {
            param($v)
            return "Owner de '$($v.parametros.aplicacion)' -> $($v.parametros.usuario)"
        }

        # Definición de parámetros para PreguntarUI (orden + prompt + default)
        ParametrosUI = @(
            @{ Nombre = 'usuario';    Prompt = 'UPN del usuario (owner)';            Default = $null }
            @{ Nombre = 'aplicacion'; Prompt = 'DisplayName de la aplicación';       Default = $null }
        )
    }

    'GroupOwner' = @{
        Nivel     = 'Free'
        DependeDe = @('Grupos','Usuarios')

        Validar = {
            param($v)
            $errores = @()
            if (-not $v.PSObject.Properties['parametros'] -or $null -eq $v.parametros) {
                $errores += "falta 'parametros'."
                return $errores
            }
            if ([string]::IsNullOrWhiteSpace($v.parametros.usuario)) {
                $errores += "falta 'parametros.usuario'."
            }
            if ([string]::IsNullOrWhiteSpace($v.parametros.grupo)) {
                $errores += "falta 'parametros.grupo'."
            }
            return $errores
        }

        Aplicar = {
            param($v, $Contexto)
            return (Invoke-VulnGroupOwner -Vulnerabilidad $v -Contexto $Contexto)
        }

        Revertir = {
            param($Objeto, $Contexto)
            return (Invoke-RevertirVulnGroupOwner -Objeto $Objeto)
        }

        Describir = {
            param($v)
            return "Owner de '$($v.parametros.grupo)' -> $($v.parametros.usuario)"
        }

        ParametrosUI = @(
            @{ Nombre = 'usuario'; Prompt = 'UPN del usuario (owner)'; Default = $null }
            @{ Nombre = 'grupo';   Prompt = 'DisplayName del grupo';   Default = $null }
        )
    }

    'ApplicationSecret' = @{
        Nivel     = 'Free'
        DependeDe = @('Aplicaciones')

        Validar = {
            param($v)
            $errores = @()
            if (-not $v.PSObject.Properties['parametros'] -or $null -eq $v.parametros) {
                $errores += "falta 'parametros'."
                return $errores
            }
            if ([string]::IsNullOrWhiteSpace($v.parametros.aplicacion)) {
                $errores += "falta 'parametros.aplicacion'."
            }
            if ($v.parametros.PSObject.Properties['dias'] -and $null -ne $v.parametros.dias) {
                if ([int]$v.parametros.dias -lt 1 -or [int]$v.parametros.dias -gt 730) {
                    $errores += "'parametros.dias' debe estar entre 1 y 730."
                }
            }
            return $errores
        }

        Aplicar = {
            param($v, $Contexto)
            return (Invoke-VulnApplicationSecret -Vulnerabilidad $v -Contexto $Contexto)
        }

        Revertir = {
            param($Objeto, $Contexto)
            return (Invoke-RevertirVulnApplicationSecret -Objeto $Objeto)
        }

        Describir = {
            param($v)
            return "Client secret en '$($v.parametros.aplicacion)'"
        }

        ParametrosUI = @(
            @{ Nombre = 'aplicacion'; Prompt = 'DisplayName de la aplicación'; Default = $null }
            @{ Nombre = 'dias';       Prompt = 'Días hasta expirar';           Default = 365 }
        )
    }

    'PimEligibleRole' = @{
        Nivel     = 'P2'
        DependeDe = @('Usuarios')

        Validar = {
            param($v)
            $errores = @()
            if (-not $v.PSObject.Properties['parametros'] -or $null -eq $v.parametros) {
                $errores += "falta 'parametros'."
                return $errores
            }
            if ([string]::IsNullOrWhiteSpace($v.parametros.usuario)) {
                $errores += "falta 'parametros.usuario'."
            }
            if ([string]::IsNullOrWhiteSpace($v.parametros.rol)) {
                $errores += "falta 'parametros.rol'."
            }
            if ($v.parametros.PSObject.Properties['duracion'] -and $v.parametros.duracion) {
                if ($v.parametros.duracion -notmatch '^PT\d+[HM]$') {
                    $errores += "'parametros.duracion' inválida ('$($v.parametros.duracion)'). Formato: PT8H, PT30M."
                }
            }
            return $errores
        }

        Aplicar = {
            param($v, $Contexto)
            return $null
        }

        Revertir = {
            param($Objeto, $Contexto)
            return $false
        }

        PreRevertir = {
            param($Objetos, $Contexto)
            foreach ($o in @($Objetos)) {
                if ($null -eq $o -or $null -eq $o.datos) { continue }
                $userId = if ($o.datos.PSObject.Properties['userId']) { $o.datos.userId } else { $null }
                $roleDefinitionId = if ($o.datos.PSObject.Properties['roleDefinitionId']) { $o.datos.roleDefinitionId } else { $null }
                if (-not $userId -or -not $roleDefinitionId) { continue }

                try {
                    $activas = Get-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
                        -Filter "principalId eq '$userId' and roleDefinitionId eq '$roleDefinitionId'" `
                        -All -ErrorAction SilentlyContinue
                    foreach ($a in @($activas)) {
                        if ($a.Status -eq 'Provisioned' -and $a.DirectoryScopeId -eq '/') {
                            $null = Remove-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
                                -UnifiedRoleAssignmentScheduleRequestId $a.Id `
                                -Confirm:$false -ErrorAction SilentlyContinue
                            Write-LabInfo "Asignación PIM activa cancelada para '$userId' / rol '$roleDefinitionId'."
                        }
                    }
                } catch {
                    Write-LabWarn "No se pudo cancelar la asignación PIM activa de '$($o.id)': $($_.Exception.Message)"
                }
            }
        }

        Describir = {
            param($v)
            return "PIM '$($v.parametros.rol)' -> $($v.parametros.usuario)"
        }

        ParametrosUI = @(
            @{ Nombre = 'usuario';  Prompt = 'UPN del usuario';                                       Default = $null }
            @{ Nombre = 'rol';      Prompt = 'Nombre del rol (ej. Global Administrator)';              Default = $null }
            @{ Nombre = 'duracion'; Prompt = 'Duración (ISO 8601)';                                   Default = 'PT8H' }
        )
    }
}

# ============================================================
# FUNCIONES AUXILIARES: MENÚ
# ============================================================

function Get-VulnTiposDisponiblesAgrupados {
    <#
    .SYNOPSIS
        Devuelve los tipos de vulnerabilidad agrupados por nivel, con estado
        (disponible/no disponible y motivo).
    .DESCRIPTION
        Estructura de retorno:
          @{
            NivelEfectivo    = 'P1'
            TotalDisponibles = 3
            Motivo           = $null   # si TotalDisponibles = 0
            PorNivel         = @{
              'Free' = @(
                @{ Nombre='ServicePrincipalOwner'; Disponible=$true;  Motivo=$null }
                @{ Nombre='GroupOwner';            Disponible=$true;  Motivo=$null }
                @{ Nombre='ApplicationSecret';     Disponible=$true;  Motivo=$null }
              )
              'P2'   = @(
                @{ Nombre='PimEligibleRole';       Disponible=$false; Motivo='requiere nivel P2 (efectivo: P1)' }
              )
            }
          }

        PimEligibleRole se marca como no disponible si cap_pim.ps1 no está
        registrada, aunque el nivel efectivo sea P2.
    #>
    param($Contexto)

    $nivelEfectivo = if ($Contexto -and $Contexto.ContainsKey('NivelEfectivo') -and $Contexto.NivelEfectivo) {
        $Contexto.NivelEfectivo
    } elseif ($Contexto -and $Contexto.ContainsKey('Config')) {
        Get-LabNivelEfectivo -Config $Contexto.Config
    } else {
        'Free'
    }
    $ordenEfectivo = Get-LabNivelOrden -Nivel $nivelEfectivo

    $porNivel = @{}
    $totalDisponibles = 0

    foreach ($nombreTipo in ($script:VulnTipos.Keys | Sort-Object)) {
        $meta = $script:VulnTipos[$nombreTipo]
        $nivelTipo = $meta.Nivel
        $ordenTipo = Get-LabNivelOrden -Nivel $nivelTipo

        $disponible = $true
        $motivo = $null

        if ($ordenTipo -gt $ordenEfectivo) {
            $disponible = $false
            $motivo = "requiere $nivelTipo (efectivo: $nivelEfectivo)"
        } elseif ($nombreTipo -eq 'PimEligibleRole' -and -not (Test-LabCapacidadRegistrada -Nombre 'Pim')) {
            $disponible = $false
            $motivo = "requiere cap_pim.ps1 (carpeta p2 desactivada)"
        }

        if (-not $porNivel.ContainsKey($nivelTipo)) {
            $porNivel[$nivelTipo] = @()
        }
        $porNivel[$nivelTipo] += [pscustomobject]@{
            Nombre     = $nombreTipo
            Disponible = $disponible
            Motivo     = $motivo
        }

        if ($disponible) { $totalDisponibles++ }
    }

    $motivoGlobal = if ($totalDisponibles -eq 0) {
        "No hay tipos de vulnerabilidad disponibles para el nivel efectivo '$nivelEfectivo'."
    } else {
        $null
    }

    return [pscustomobject]@{
        NivelEfectivo    = $nivelEfectivo
        TotalDisponibles = $totalDisponibles
        Motivo           = $motivoGlobal
        PorNivel         = $porNivel
    }
}

function Read-VulnParametros {
    <#
    .SYNOPSIS
        Pide los parámetros de una vulnerabilidad, con defaults entre corchetes.
    .DESCRIPTION
        Recorre $script:VulnTipos[$Tipo].ParametrosUI y pide cada parámetro.
        Si hay un valor previo en $Parametros, se usa como default y Enter lo
        mantiene. Si no, se pide.

        Los valores numéricos se convierten a [int] si el default es [int].
        Los strings se dejan como string.
    .PARAMETER Tipo
        Tipo de vulnerabilidad.
    .PARAMETER Parametros
        Hashtable con parámetros previos (puede ser vacío).
    .OUTPUTS
        Hashtable con los parámetros finales.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tipo,

        [Parameter(Mandatory = $false)]
        [hashtable]$Parametros = @{}
    )

    $meta = $script:VulnTipos[$Tipo]
    if (-not $meta -or -not $meta.ContainsKey('ParametrosUI')) {
        return $Parametros
    }

    $resultado = @{}

    foreach ($p in @($meta.ParametrosUI)) {
        $nombreParam = $p.Nombre
        $prompt = $p.Prompt

        # Valor previo si existe
        $previo = $null
        if ($Parametros -and $Parametros.ContainsKey($nombreParam)) {
            $previo = $Parametros[$nombreParam]
        } elseif ($p.Default -ne $null) {
            $previo = $p.Default
        }

        $promptConDefault = if ($null -ne $previo -and -not [string]::IsNullOrWhiteSpace([string]$previo)) {
            "  $prompt [$previo]"
        } else {
            "  $prompt"
        }

        $valor = Read-Host $promptConDefault

        if ([string]::IsNullOrWhiteSpace($valor)) {
            $valor = $previo
        }

        # Conversión de tipo según el default
        if ($null -ne $previo -and $previo -is [int]) {
            if ($valor -match '^\d+$') {
                $valor = [int]$valor
            }
        }

        $resultado[$nombreParam] = $valor
    }

    return $resultado
}

function Read-VulnDesdeCatalogo {
    <#
    .SYNOPSIS
        Permite cargar una vulnerabilidad del catálogo por nombre.
    .DESCRIPTION
        Lista las vulnerabilidades del catálogo agrupadas por nivel del tipo.
        Los tipos no disponibles se muestran deshabilitados con motivo.
        Al elegir una, la carga con Get-LabVulnerabilidad y permite
        sobrescribir sus parámetros (A + B).
    .OUTPUTS
        PSCustomObject con { nombre, tipo, parametros } o $null si se cancela.
    #>
    param($Contexto)

    $agrupados = Get-VulnTiposDisponiblesAgrupados -Contexto $Contexto

    # Mapa de tipo -> disponible (para filtrar catálogo)
    $tiposDisponibles = @{}
    foreach ($nivel in $agrupados.PorNivel.Keys) {
        foreach ($item in @($agrupados.PorNivel[$nivel])) {
            $tiposDisponibles[$item.Nombre] = $item.Disponible
        }
    }

    # Obtener catálogo
    $nombres = @(Get-LabVulnerabilidadesDisponibles)
    if ($nombres.Count -eq 0) {
        Write-LabWarn 'El catálogo de vulnerabilidades está vacío (escenarios/vulnerab/).'
        return $null
    }

    # Cargar cada una y agrupar por nivel del tipo
    $porNivel = @{}
    $opciones = @()

    foreach ($nombre in $nombres) {
        try {
            $v = Get-LabVulnerabilidad -Nombre $nombre
        } catch {
            Write-LabWarn "No se pudo cargar la vulnerabilidad '$nombre': $($_.Exception.Message)"
            continue
        }

        $tipo = $v.Tipo
        $meta = $script:VulnTipos[$tipo]
        $nivelTipo = if ($meta) { $meta.Nivel } else { '?' }

        $disponible = if ($tiposDisponibles.ContainsKey($tipo)) { $tiposDisponibles[$tipo] } else { $false }
        $motivo = if (-not $disponible) {
            if (-not $meta) { "tipo '$tipo' no registrado" }
            elseif ($tiposDisponibles.ContainsKey($tipo)) { "tipo '$tipo' no disponible en nivel efectivo" }
            else { "tipo '$tipo' no disponible" }
        } else { $null }

        if (-not $porNivel.ContainsKey($nivelTipo)) { $porNivel[$nivelTipo] = @() }
        $porNivel[$nivelTipo] += [pscustomobject]@{
            Nombre     = $nombre
            Tipo       = $tipo
            Descripcion = $v.Descripcion
            Parametros = $v.Parametros
            Disponible = $disponible
            Motivo     = $motivo
        }

        if ($disponible) { $opciones += $nombre }
    }

    if ($opciones.Count -eq 0) {
        Write-LabWarn 'No hay vulnerabilidades del catálogo disponibles para tu nivel efectivo.'
        return $null
    }

    Show-LabHeader -Titulo 'CATALOGO DE VULNERABILIDADES'

    Write-Host "  Nivel efectivo: $($agrupados.NivelEfectivo)" -ForegroundColor Gray
    Write-Host ''

    $mapaOpciones = @{}
    $contador = 0
    foreach ($nivel in @('Free','P1','P2','?')) {
        if (-not $porNivel.ContainsKey($nivel)) { continue }
        $items = @($porNivel[$nivel])
        if ($items.Count -eq 0) { continue }

        Write-Host "  --- $nivel ---" -ForegroundColor Cyan
        foreach ($item in $items) {
            if ($item.Disponible) {
                $contador++
                $mapaOpciones[$contador] = $item
                Write-Host ('    [{0}] {1}  ({2})' -f $contador, $item.Nombre, $item.Tipo)
            } else {
                Write-Host ('    [!] {0}  ({1}) — {2}' -f $item.Nombre, $item.Tipo, $item.Motivo) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
    }

    Write-Host '    [0] Volver'
    Write-Host ''

    $sel = Read-Host '  Selecciona una vulnerabilidad'
    if ([string]::IsNullOrWhiteSpace($sel) -or $sel -eq '0') { return $null }
    if (-not ($sel -match '^\d+$') -or -not $mapaOpciones.ContainsKey([int]$sel)) {
        Write-LabWarn 'Selección inválida.'
        return $null
    }

    $elegida = $mapaOpciones[[int]$sel]

    # Mostrar detalles
    Write-Host ''
    Write-Host "  Vulnerabilidad: $($elegida.Nombre)"
    Write-Host "  Tipo          : $($elegida.Tipo)"
    if ($elegida.Descripcion) {
        Write-Host "  Descripción   : $($elegida.Descripcion)"
    }
    Write-Host ''
    Write-Host '  Parámetros actuales:' -ForegroundColor Cyan
    foreach ($k in $elegida.Parametros.Keys) {
        Write-Host "    $k : $($elegida.Parametros[$k])"
    }
    Write-Host ''

    # Nombre: mantener o cambiar
    $nombreFinal = $elegida.Nombre
    $nuevoNombre = Read-Host "  Nombre de la vulnerabilidad [$nombreFinal]"
    if (-not [string]::IsNullOrWhiteSpace($nuevoNombre)) {
        $nombreFinal = $nuevoNombre
    }

    # ¿Modificar parámetros?
    $modificar = Read-Host '  ¿Quieres modificar algún parámetro? (SI/N) [N]'
    $parametrosFinales = $elegida.Parametros
    if ($modificar -eq 'SI') {
        $parametrosFinales = Read-VulnParametros -Tipo $elegida.Tipo -Parametros $elegida.Parametros
    }

    # Construir def
    $def = [pscustomobject]@{
        nombre     = $nombreFinal
        tipo       = $elegida.Tipo
        parametros = $parametrosFinales
    }

    # Validación local
    $meta = $script:VulnTipos[$elegida.Tipo]
    if ($meta) {
        $errs = & $meta.Validar $def
        if (@($errs).Count -gt 0) {
            Write-LabError 'La vulnerabilidad tiene errores de validación:'
            foreach ($e in @($errs)) { Write-Host "  - $e" -ForegroundColor Red }
            return $null
        }
    }

    return $def
}

# ============================================================
# OBTENERCLAVES (para snapshot pre-lab por capacidad)
# ============================================================
$Capacidad['ObtenerClaves'] = {
    param($Def)

    $claves = @()
    foreach ($v in @($Def)) {
        if ($null -eq $v -or -not $v.PSObject.Properties['parametros'] -or $null -eq $v.parametros) { continue }

        switch ($v.tipo) {
            'ServicePrincipalOwner' {
                if ($v.parametros.aplicacion) { $claves += "app:$($v.parametros.aplicacion)" }
                if ($v.parametros.usuario)    { $claves += "user:$($v.parametros.usuario)" }
            }
            'GroupOwner' {
                if ($v.parametros.grupo)   { $claves += "group:$($v.parametros.grupo)" }
                if ($v.parametros.usuario) { $claves += "user:$($v.parametros.usuario)" }
            }
            'ApplicationSecret' {
                if ($v.parametros.aplicacion) { $claves += "app:$($v.parametros.aplicacion)" }
            }
            'PimEligibleRole' {
                if ($v.parametros.usuario) { $claves += "user:$($v.parametros.usuario)" }
            }
        }
    }
    return @($claves | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

# ============================================================
# PREREVERTIR (orquestadora: delega en el tipo)
# ============================================================
$Capacidad['PreRevertir'] = {
    param($Objetos, $Contexto)

    foreach ($o in @($Objetos)) {
        if ($null -eq $o) { continue }
        $tipo = if ($o.PSObject.Properties['tipo']) { $o.tipo } else { $null }
        if ([string]::IsNullOrWhiteSpace($tipo) -and $o.datos -and $o.datos.PSObject.Properties['tipoVulnerabilidad']) {
            $tipo = $o.datos.tipoVulnerabilidad
        }
        if ([string]::IsNullOrWhiteSpace($tipo)) { continue }

        $meta = $script:VulnTipos[$tipo]
        if (-not $meta) { continue }
        if (-not $meta.ContainsKey('PreRevertir') -or $meta.PreRevertir -isnot [scriptblock]) { continue }

        try {
            & $meta.PreRevertir @($o) $Contexto
        } catch {
            Write-LabWarn "PreRevertir de '$tipo' falló para '$($o.id)': $($_.Exception.Message)"
        }
    }
}

# ============================================================
# FUNCIONES AUXILIARES: APLICADORES
# ============================================================

function Invoke-VulnServicePrincipalOwner {
    param($Vulnerabilidad, $Contexto)

    $upn = $Vulnerabilidad.parametros.usuario -replace '\{tenant\}', $Contexto.TenantDomain
    $appNombre = $Vulnerabilidad.parametros.aplicacion

    if ($Contexto.SnapshotPreLab -and
        $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
        $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($appNombre)) {
        Write-LabWarn "Aplicación '$appNombre' es preexistente. No se aplica ServicePrincipalOwner."
        return [pscustomobject]@{
            tipo              = 'ServicePrincipalOwner'
            aplicacion        = $appNombre
            usuario           = $upn
            objetoAfectadoObjectId = $Contexto.SnapshotPreLab.aplicaciones[$appNombre]
            estadoDetalle     = 'preexistente'
        }
    }

    $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
    if (-not $user) { throw "Usuario '$upn' no encontrado." }
    if ($user -is [array]) { $user = $user[0] }

    $app = Get-MgApplication -Filter "displayName eq '$appNombre'" -ErrorAction SilentlyContinue
    if (-not $app) { throw "Aplicación '$appNombre' no encontrada." }
    if ($app -is [array]) { $app = $app[0] }

    $sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -ErrorAction SilentlyContinue
    if (-not $sp) { throw "SP de '$appNombre' no encontrado." }
    if ($sp -is [array]) { $sp = $sp[0] }

    $owners = Get-MgServicePrincipalOwner -ServicePrincipalId $sp.Id -All -ErrorAction SilentlyContinue
    $yaEsOwner = $false
    foreach ($o in @($owners)) {
        if ($o.Id -eq $user.Id) { $yaEsOwner = $true; break }
    }

    if ($yaEsOwner) {
        Write-LabInfo "El usuario '$upn' ya es owner del SP '$appNombre' (reutilizado)."
        return [pscustomobject]@{
            tipo              = 'ServicePrincipalOwner'
            servicePrincipalId = $sp.Id
            directoryObjectId = $user.Id
            objetoAfectadoObjectId = $sp.Id
            aplicacion        = $appNombre
            usuario           = $upn
            estadoDetalle     = 'reutilizado'
        }
    }

    $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
    $null = New-MgServicePrincipalOwnerByRef -ServicePrincipalId $sp.Id -BodyParameter $body -ErrorAction Stop

    return [pscustomobject]@{
        tipo              = 'ServicePrincipalOwner'
        servicePrincipalId = $sp.Id
        directoryObjectId = $user.Id
        objetoAfectadoObjectId = $sp.Id
        aplicacion        = $appNombre
        usuario           = $upn
        estadoDetalle     = 'creado'
    }
}

function Invoke-VulnGroupOwner {
    param($Vulnerabilidad, $Contexto)

    $upn = $Vulnerabilidad.parametros.usuario -replace '\{tenant\}', $Contexto.TenantDomain
    $nombreGrupo = $Vulnerabilidad.parametros.grupo

    if ($Contexto.SnapshotPreLab -and
        $Contexto.SnapshotPreLab.ContainsKey('grupos') -and
        $Contexto.SnapshotPreLab.grupos.ContainsKey($nombreGrupo)) {
        Write-LabWarn "Grupo '$nombreGrupo' es preexistente. No se aplica GroupOwner."
        return [pscustomobject]@{
            tipo              = 'GroupOwner'
            grupo             = $nombreGrupo
            usuario           = $upn
            objetoAfectadoObjectId = $Contexto.SnapshotPreLab.grupos[$nombreGrupo]
            estadoDetalle     = 'preexistente'
        }
    }

    $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
    if (-not $user) { throw "Usuario '$upn' no encontrado." }
    if ($user -is [array]) { $user = $user[0] }

    $grupo = Get-MgGroup -Filter "displayName eq '$nombreGrupo'" -ErrorAction SilentlyContinue
    if (-not $grupo) { throw "Grupo '$nombreGrupo' no encontrado." }
    if ($grupo -is [array]) { $grupo = $grupo[0] }

    $owners = Get-MgGroupOwner -GroupId $grupo.Id -All -ErrorAction SilentlyContinue
    $yaEsOwner = $false
    foreach ($o in @($owners)) {
        if ($o.Id -eq $user.Id) { $yaEsOwner = $true; break }
    }

    if ($yaEsOwner) {
        Write-LabInfo "El usuario '$upn' ya es owner del grupo '$nombreGrupo' (reutilizado)."
        return [pscustomobject]@{
            tipo              = 'GroupOwner'
            groupId           = $grupo.Id
            directoryObjectId = $user.Id
            objetoAfectadoObjectId = $grupo.Id
            grupo             = $nombreGrupo
            usuario           = $upn
            estadoDetalle     = 'reutilizado'
        }
    }

    $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
    $null = New-MgGroupOwnerByRef -GroupId $grupo.Id -BodyParameter $body -ErrorAction Stop

    return [pscustomobject]@{
        tipo              = 'GroupOwner'
        groupId           = $grupo.Id
        directoryObjectId = $user.Id
        objetoAfectadoObjectId = $grupo.Id
        grupo             = $nombreGrupo
        usuario           = $upn
        estadoDetalle     = 'creado'
    }
}

function Invoke-VulnApplicationSecret {
    param($Vulnerabilidad, $Contexto)

    $appNombre = $Vulnerabilidad.parametros.aplicacion
    $dias = if ($Vulnerabilidad.parametros.PSObject.Properties['dias'] -and $null -ne $Vulnerabilidad.parametros.dias) {
        [int]$Vulnerabilidad.parametros.dias
    } else {
        365
    }

    if ($Contexto.SnapshotPreLab -and
        $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
        $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($appNombre)) {
        Write-LabWarn "Aplicación '$appNombre' es preexistente. No se aplica ApplicationSecret."
        return [pscustomobject]@{
            tipo              = 'ApplicationSecret'
            aplicacion        = $appNombre
            objetoAfectadoObjectId = $Contexto.SnapshotPreLab.aplicaciones[$appNombre]
            estadoDetalle     = 'preexistente'
        }
    }

    $app = Get-MgApplication -Filter "displayName eq '$appNombre'" -ErrorAction SilentlyContinue
    if (-not $app) { throw "Aplicación '$appNombre' no encontrada." }
    if ($app -is [array]) { $app = $app[0] }

    $displayName = "Vuln secret - $($Vulnerabilidad.nombre)"

    $credenciales = @()
    if ($app.PasswordCredentials) { $credenciales = @($app.PasswordCredentials) }
    foreach ($pc in $credenciales) {
        if ($pc.DisplayName -eq $displayName) {
            Write-LabInfo "La credencial '$displayName' ya existe en '$appNombre' (reutilizada)."
            return [pscustomobject]@{
                tipo              = 'ApplicationSecret'
                applicationId     = $app.Id
                keyId             = $pc.KeyId
                objetoAfectadoObjectId = $app.Id
                aplicacion        = $appNombre
                displayName       = $displayName
                estadoDetalle     = 'reutilizado'
            }
        }
    }

    $endDateTime = (Get-Date).AddDays($dias)
    $cred = @{
        displayName = $displayName
        endDateTime = $endDateTime
    }
    $result = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential $cred -ErrorAction Stop

    $secretoMostrar = [pscustomobject]@{
        nombreVulnerabilidad = $Vulnerabilidad.nombre
        aplicacion           = $appNombre
        displayName          = $displayName
        keyId                = $result.KeyId
        secreto              = $result.SecretText
        expira               = $endDateTime.ToString('yyyy-MM-dd')
    }

    return [pscustomobject]@{
        tipo              = 'ApplicationSecret'
        applicationId     = $app.Id
        keyId             = $result.KeyId
        objetoAfectadoObjectId = $app.Id
        aplicacion        = $appNombre
        displayName       = $displayName
        secretoMostrar    = $secretoMostrar
        estadoDetalle     = 'creado'
    }
}

# ============================================================
# FUNCIONES AUXILIARES: REVERSORES
# ============================================================

function Invoke-RevertirVulnServicePrincipalOwner {
    param($Objeto)

    if ($null -eq $Objeto -or $null -eq $Objeto.datos) { return $true }

    $spId = if ($Objeto.datos.PSObject.Properties['servicePrincipalId']) { $Objeto.datos.servicePrincipalId } else { $null }
    $dirId = if ($Objeto.datos.PSObject.Properties['directoryObjectId']) { $Objeto.datos.directoryObjectId } else { $null }
    if (-not $spId -or -not $dirId) { return $true }

    try {
        $owners = Get-MgServicePrincipalOwner -ServicePrincipalId $spId -All -ErrorAction SilentlyContinue
        $existe = $false
        foreach ($o in @($owners)) {
            if ($o.Id -eq $dirId) { $existe = $true; break }
        }
        if (-not $existe) { return $true }

        $null = Remove-MgServicePrincipalOwnerByRef -ServicePrincipalId $spId -DirectoryObjectId $dirId -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
        return $false
    }
}

function Invoke-RevertirVulnGroupOwner {
    param($Objeto)

    if ($null -eq $Objeto -or $null -eq $Objeto.datos) { return $true }

    $groupId = if ($Objeto.datos.PSObject.Properties['groupId']) { $Objeto.datos.groupId } else { $null }
    $dirId = if ($Objeto.datos.PSObject.Properties['directoryObjectId']) { $Objeto.datos.directoryObjectId } else { $null }
    if (-not $groupId -or -not $dirId) { return $true }

    try {
        $owners = Get-MgGroupOwner -GroupId $groupId -All -ErrorAction SilentlyContinue
        $existe = $false
        foreach ($o in @($owners)) {
            if ($o.Id -eq $dirId) { $existe = $true; break }
        }
        if (-not $existe) { return $true }

        $null = Remove-MgGroupOwnerByRef -GroupId $groupId -DirectoryObjectId $dirId -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
        return $false
    }
}

function Invoke-RevertirVulnApplicationSecret {
    param($Objeto)

    if ($null -eq $Objeto -or $null -eq $Objeto.datos) { return $true }

    $appId = if ($Objeto.datos.PSObject.Properties['applicationId']) { $Objeto.datos.applicationId } else { $null }
    $keyId = if ($Objeto.datos.PSObject.Properties['keyId']) { $Objeto.datos.keyId } else { $null }
    if (-not $appId -or -not $keyId) { return $true }

    try {
        $null = Remove-MgApplicationPassword -ApplicationId $appId -KeyId $keyId -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
        return $false
    }
}

# ============================================================
# REGISTRO
# ============================================================
Register-LabCapacidad -Capacidad $Capacidad
