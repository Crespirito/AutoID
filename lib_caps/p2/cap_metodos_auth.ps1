<#
.SYNOPSIS
    Capacidad: Métodos de autenticación (Temporary Access Pass).
.DESCRIPTION
    Crea Temporary Access Pass (TAP) para usuarios a partir de la sección
    'metodosAuth' del escenario.

    Estructura de la sección 'metodosAuth':
      { usuario, lifetimeInMinutes?: 60, isUsableOnce?: true, startDateTime?: "..." }

    LICENCIA:
    TAP requiere Microsoft Entra ID P1 (o superior) para cada usuario
    que lo reciba. TestDisponible consulta los SKUs del tenant
    (cacheada vía Get-LabSubscribedSku).

    SEGURIDAD:
    - El código TAP solo se devuelve en la creación y no se puede
      recuperar después. Se muestra UNA SOLA VEZ al operador, y SOLO
      si Graph lo devuelve en la respuesta.
    - Si isUsableOnce = $false, Graph NO devuelve el código. En ese caso
      se avisa claramente al operador (no se finge que hay código).
    - Si el usuario es preexistente (snapshot pre-lab), no se le crea TAP.
    - Si el usuario ya tiene un método de autenticación fuerte, Graph
      fallará y se avisará.

    DEPENDENCIAS: Usuarios.
    NIVEL: P1.
.NOTES
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

$Capacidad = @{
    Nombre      = 'MetodosAuth'
    Descripcion = 'Métodos de autenticación (TAP)'
    SeccionJson = 'metodosAuth'
    Alias       = @('metodos_auth', 'authenticationMethods')
    Nivel       = 'P1'
    DependeDe   = @('Usuarios')
    PermisosApp = @('UserAuthenticationMethod.ReadWrite.All','User.Read.All')

    TestDisponible = {
        param($Contexto)
        if (-not (Test-LabGraphSession)) {
            return [pscustomobject]@{ Disponible = $false; Motivo = 'Sin sesión de Graph' }
        }
        try {
            # N7: cache de SKUs
            $skus = @(Get-LabSubscribedSku)
            $tieneP1 = $false
            foreach ($sku in $skus) {
                if ($sku.PSObject.Properties['ServicePlans'] -and $null -ne $sku.ServicePlans) {
                    foreach ($plan in @($sku.ServicePlans)) {
                        if ($plan.ServicePlanName -in @('AAD_PREMIUM','AAD_PREMIUM_P2') -and $plan.ProvisioningStatus -eq 'Success') {
                            $tieneP1 = $true
                            break
                        }
                    }
                }
                if ($tieneP1) { break }
            }
            if (-not $tieneP1) {
                return [pscustomobject]@{ Disponible = $false; Motivo = 'Requiere licencia Entra ID P1 (AAD_PREMIUM)' }
            }
            return [pscustomobject]@{ Disponible = $true; Motivo = $null }
        } catch {
            Write-LabWarn "No se pudieron consultar los SKUs del tenant: $($_.Exception.Message)"
            return [pscustomobject]@{ Disponible = $true; Motivo = $null }
        }
    }

    ValidarDef = {
        param($Def)
        $errores = @()
        $i = 0
        foreach ($m in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($m.usuario)) {
                $errores += "Método de autenticación #$i sin 'usuario'."
            }
            if ($m.PSObject.Properties['lifetimeInMinutes'] -and $null -ne $m.lifetimeInMinutes) {
                $lt = [int]$m.lifetimeInMinutes
                if ($lt -lt 10 -or $lt -gt 43200) {
                    # CORREGIDO: sintaxis de variables
                    $errores += "Método #${i}: 'lifetimeInMinutes' debe estar entre 10 y 43200."
                }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { $_.usuario }
        return "Métodos de autenticación TAP ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($m in @($Def)) {
            $upn = $m.usuario -replace '\{tenant\}', $Contexto.TenantDomain

            $lifetime = if ($m.PSObject.Properties['lifetimeInMinutes'] -and $null -ne $m.lifetimeInMinutes) {
                [int]$m.lifetimeInMinutes
            } else {
                60
            }

            $isUsableOnce = $true
            if ($m.PSObject.Properties['isUsableOnce'] -and $null -ne $m.isUsableOnce) {
                $isUsableOnce = [bool]$m.isUsableOnce
            }

            $startDateTime = if ($m.PSObject.Properties['startDateTime'] -and -not [string]::IsNullOrWhiteSpace($m.startDateTime)) {
                $m.startDateTime
            } else {
                (Get-Date).ToString('o')
            }

            # --- 1. Snapshot pre-lab ---
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('usuarios') -and
                $Contexto.SnapshotPreLab.usuarios.ContainsKey($upn.ToLowerInvariant())) {
                Write-LabWarn "El usuario '$upn' ya existía antes del laboratorio. No se le crea TAP."
                $creados += [pscustomobject]@{
                    tipo          = 'MetodoAuth'
                    upn           = $upn
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # --- 2. Buscar usuario ---
            $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
            if (-not $user) {
                Write-LabWarn "Usuario '$upn' no encontrado para TAP; se omite."
                continue
            }
            if ($user -is [array]) { $user = $user[0] }

            # --- 3. Crear TAP ---
            $body = @{
                lifetimeInMinutes = $lifetime
                isUsableOnce      = $isUsableOnce
                startDateTime     = $startDateTime
            }

            try {
                $resultado = New-MgUserAuthenticationTemporaryAccessPassMethod -UserId $user.Id -BodyParameter $body -ErrorAction Stop
            } catch {
                Write-LabWarn "No se pudo crear TAP para '$upn': $($_.Exception.Message)"
                continue
            }

            if ($null -eq $resultado) {
                Write-LabWarn "New-MgUserAuthenticationTemporaryAccessPassMethod no devolvió objeto para '$upn'."
                continue
            }
            if ($resultado -is [array]) { $resultado = $resultado[0] }

            # --- 4. N16: TAP code puede no venir ---
            $tapCode = $null
            if ($resultado.PSObject.Properties['TemporaryAccessPass'] -and -not [string]::IsNullOrWhiteSpace([string]$resultado.TemporaryAccessPass)) {
                $tapCode = [string]$resultado.TemporaryAccessPass
            }

            Write-Verbose "   -> TAP creado para '$upn' (methodId: $($resultado.Id))"

            if (-not [string]::IsNullOrWhiteSpace($tapCode)) {
                Write-Host ''
                Write-Host '=== TEMPORARY ACCESS PASS CREADO (MOSTRAR UNA SOLA VEZ) ===' -ForegroundColor Yellow
                Write-Host "  Usuario : $upn"
                Write-Host "  Código  : $tapCode" -ForegroundColor Green
                Write-Host "  Expira  : $((Get-Date).AddMinutes($lifetime).ToString('yyyy-MM-dd HH:mm'))"
                Write-Host "  Un solo uso: $isUsableOnce"
                Write-Host ''
                Write-Host 'Si pierdes el código, tendrás que crear un TAP nuevo.' -ForegroundColor Yellow
                Write-Host ''
            } else {
                # N16: aviso claro cuando Graph no devuelve el código
                Write-Host ''
                Write-LabWarn "TAP creado para '$upn' pero Graph NO ha devuelto el código."
                Write-LabInfo "Motivo habitual: isUsableOnce = `$false. Graph solo devuelve el código en la respuesta cuando el TAP es de un solo uso."
                Write-LabInfo "Para obtener el código: consulta el usuario en el portal de Entra ID, o vuelve a crear el TAP con isUsableOnce = `$true."
                Write-Host "  Usuario : $upn"
                Write-Host "  Expira  : $((Get-Date).AddMinutes($lifetime).ToString('yyyy-MM-dd HH:mm'))"
                Write-Host "  Un solo uso: $isUsableOnce"
                Write-Host ''
            }

            $creados += [pscustomobject]@{
                tipo              = 'MetodoAuth'
                upn               = $upn
                userId            = $user.Id
                methodId          = $resultado.Id
                lifetimeInMinutes = $lifetime
                isUsableOnce      = $isUsableOnce
                estadoDetalle     = 'creado'
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -ne 'MetodoAuth') { return $false }

        $userId = if ($Objeto.datos) { $Objeto.datos.userId } else { $null }
        $methodId = if ($Objeto.datos) { $Objeto.datos.methodId } else { $null }

        if (-not $userId -or -not $methodId) {
            return $true
        }

        try {
            $metodos = Get-MgUserAuthenticationMethod -UserId $userId -ErrorAction SilentlyContinue
            $existe = $false
            foreach ($m in @($metodos)) {
                if ($m.Id -eq $methodId) { $existe = $true; break }
            }
            if (-not $existe) { return $true }

            $null = Remove-MgUserAuthenticationMethod -UserId $userId -AuthenticationMethodId $methodId -Confirm:$false -ErrorAction Stop
            return $true
        } catch {
            if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
            Write-LabWarn "No se pudo revocar el TAP '$($Objeto.id)': $($_.Exception.Message)"
            return $false
        }
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nuevo Temporary Access Pass (TAP)'

        $upn = Read-Host '  UPN del usuario'
        if ([string]::IsNullOrWhiteSpace($upn)) {
            Write-LabWarn 'UPN vacío. Cancelando.'
            return $null
        }

        if ($Contexto.SnapshotPreLab -and
            $Contexto.SnapshotPreLab.ContainsKey('usuarios') -and
            $Contexto.SnapshotPreLab.usuarios.ContainsKey($upn.ToLowerInvariant())) {
            Write-LabWarn "El usuario '$upn' ya existía antes del laboratorio. No se le puede crear TAP."
            return $null
        }

        $lifetime = Read-Host '  Duración en minutos [60] (10-43200)'
        if ([string]::IsNullOrWhiteSpace($lifetime) -or -not ($lifetime -match '^\d+$')) {
            $lifetime = 60
        }

        $once = Read-Host '  ¿Un solo uso? (SI/N) [SI]'
        $isUsableOnce = ($once -ne 'N')

        return [pscustomobject]@{
            usuario           = $upn
            lifetimeInMinutes = [int]$lifetime
            isUsableOnce      = $isUsableOnce
        }
    }
}

$null = Register-LabCapacidad -Capacidad $Capacidad