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
    que lo reciba. TestDisponible consulta los SKUs del tenant y comprueba
    si existe el plan de servicio 'AAD_PREMIUM' o 'AAD_PREMIUM_P2' con
    estado 'Success'. Si no existe, la capacidad no se ofrece.

    SEGURIDAD:
    - El código TAP solo se devuelve en la creación y no se puede
      recuperar después. Se muestra UNA SOLA VEZ al operador.
    - Si el usuario es preexistente (snapshot pre-lab), no se le crea TAP.
    - TAP solo funciona si el usuario no tiene ya un método de
      autenticación sin contraseña fuerte (FIDO2, Windows Hello, etc.).
      Si falla, se avisa y se omite.

    DEPENDENCIAS: Usuarios.

    NIVEL: P1.
#>

$Capacidad = @{
    Nombre       = 'MetodosAuth'
    Descripcion  = 'Métodos de autenticación (TAP)'
    SeccionJson  = 'metodosAuth'
    Alias        = @('metodosAuth','metodos_auth','authenticationMethods')
    Nivel        = 'P1'
    DependeDe    = @('Usuarios')
    PermisosApp  = @('UserAuthenticationMethod.ReadWrite.All','User.Read.All')

    TestDisponible = {
        param($Contexto)
        if (-not (Test-LabGraphSession)) {
            return [pscustomobject]@{ Disponible = $false; Motivo = 'Sin sesión de Graph' }
        }
        try {
            $skus = Get-MgSubscribedSku -ErrorAction Stop
            $tieneP1 = $false
            foreach ($sku in @($skus)) {
                foreach ($plan in @($sku.ServicePlans)) {
                    if ($plan.ServicePlanName -in @('AAD_PREMIUM','AAD_PREMIUM_P2') -and
                        $plan.ProvisioningStatus -eq 'Success') {
                        $tieneP1 = $true
                        break
                    }
                }
                if ($tieneP1) { break }
            }
            if (-not $tieneP1) {
                return [pscustomobject]@{
                    Disponible = $false
                    Motivo     = 'Requiere licencia Entra ID P1 (AAD_PREMIUM)'
                }
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
                    $errores += "Método #`${i}: 'lifetimeInMinutes' debe estar entre 10 y 43200."
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
            $isUsableOnce = if ($m.PSObject.Properties['isUsableOnce'] -and $null -ne $m.isUsableOnce) {
                [bool]$m.isUsableOnce
            } else {
                $true
            }
            $startDateTime = if ($m.PSObject.Properties['startDateTime'] -and $m.startDateTime) {
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
                if ($_.Exception.Message -match 'already|method|strong') {
                    Write-LabWarn "No se pudo crear TAP para '$upn': el usuario ya tiene un método de autenticación fuerte. $($_.Exception.Message)"
                } else {
                    Write-LabWarn "No se pudo crear TAP para '$upn': $($_.Exception.Message)"
                }
                continue
            }

            if ($null -eq $resultado) {
                Write-LabWarn "New-MgUserAuthenticationTemporaryAccessPassMethod no devolvió objeto para '$upn'."
                continue
            }

            # El código TAP solo se devuelve aquí. No se guarda en el manifiesto.
            $tapCode = $resultado.TemporaryAccessPass

            Write-Verbose "   -> TAP creado para '$upn'"

            # Mostrar el código TAP UNA SOLA VEZ
            Write-Host ''
            Write-Host '=== TEMPORARY ACCESS PASS CREADO (MOSTRAR UNA SOLA VEZ) ===' -ForegroundColor Yellow
            Write-Host "  Usuario : $upn"
            Write-Host "  Código  : $tapCode" -ForegroundColor Green
            Write-Host "  Expira  : $((Get-Date).AddMinutes($lifetime).ToString('yyyy-MM-dd HH:mm'))"
            Write-Host "  Un solo uso: $isUsableOnce"
            Write-Host ''
            Write-Host 'Si pierdes el código, tendrás que crear un TAP nuevo.' -ForegroundColor Yellow
            Write-Host ''

            $creados += [pscustomobject]@{
                tipo              = 'MetodoAuth'
                upn               = $upn
                userId            = $user.Id
                methodId          = $resultado.Id
                lifetimeInMinutes = $lifetime
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
            # Preexistente o sin datos: no hay nada que revertir
            return $true
        }

        try {
            # Comprobar si el método existe
            $metodo = Get-MgUserAuthenticationMethod -UserId $userId -ErrorAction SilentlyContinue
            $existe = $false
            foreach ($m in @($metodo)) {
                if ($m.Id -eq $methodId) { $existe = $true; break }
            }
            if (-not $existe) { return $true }  # idempotente

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

Register-LabCapacidad -Capacidad $Capacidad
