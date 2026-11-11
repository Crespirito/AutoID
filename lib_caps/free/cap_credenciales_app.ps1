<#
.SYNOPSIS
    Capacidad: Credenciales de aplicación (client secrets).
.DESCRIPTION
    Añade credenciales (client secrets) a una aplicación existente a partir
    de la sección 'credencialesApp' del escenario.

    SEGURIDAD DE SECRETOS:
    El SecretText de un client secret SOLO se devuelve en la creación y
    NO se puede recuperar después. Esta capacidad:
      - NO guarda el secreto en el manifiesto.
      - Muestra el secreto UNA SOLA VEZ al operador en el momento de crearlo.
      - Solo guarda el keyId en el manifiesto, para poder revertir la
        credencial sin necesidad de conocer el secreto.

    SEGURIDAD DE PREEXISTENTES:
    - Si la aplicación es preexistente (snapshot pre-lab), no se añaden
      credenciales y se marca 'preexistente'.
    - Si la credencial ya existía (mismo displayName), se marca 'reutilizado'
      y no se crea otra.

    DEPENDENCIAS: Aplicaciones (necesita el objectId de la app).

    NIVEL: Free.
#>

$Capacidad = @{
    Nombre      = 'CredencialesApp'
    SeccionJson = 'credencialesApp'
    Alias       = @('credencialesApp','credenciales_app','secrets')
    Nivel       = 'Free'
    DependeDe   = @('Aplicaciones')
    PermisosApp = @('Application.ReadWrite.All')

    TestDisponible = {
        param($Contexto)
        if (-not (Test-LabGraphSession)) {
            return [pscustomobject]@{ Disponible = $false; Motivo = 'Sin sesión de Graph' }
        }
        return [pscustomobject]@{ Disponible = $true; Motivo = $null }
    }

    ValidarDef = {
        param($Def)
        $errores = @()
        $i = 0
        foreach ($c in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($c.aplicacion)) {
                $errores += "Credencial #$i sin 'aplicacion'."
            }
            if ([string]::IsNullOrWhiteSpace($c.displayName)) {
                $errores += "Credencial #$i sin 'displayName'."
            }
            if ($c.PSObject.Properties['endDateTime'] -and $null -ne $c.endDateTime) {
                try {
                    $fecha = [datetime]$c.endDateTime
                    if ($fecha -lt (Get-Date)) {
                        $errores += "Credencial #`${i}: 'endDateTime' ya ha pasado ($fecha)."
                    }
                } catch {
                    $errores += "Credencial #`${i}: 'endDateTime' inválido ('$($c.endDateTime)')."
                }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { "$($_.aplicacion) / $($_.displayName)" }
        return "Credenciales de app ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()
        $secretosMostrados = @{}

        foreach ($c in @($Def)) {
            $appNombre = $c.aplicacion
            $displayName = $c.displayName

            # --- 1. Snapshot pre-lab ---
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
                $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($appNombre)) {
                Write-LabWarn "Aplicación '$appNombre' es preexistente. No se añaden credenciales."
                $creados += [pscustomobject]@{
                    tipo          = 'CredencialApp'
                    aplicacion    = $appNombre
                    displayName   = $displayName
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # --- 2. Buscar la app ---
            $app = Get-MgApplication -Filter "displayName eq '$appNombre'" -ErrorAction SilentlyContinue
            if (-not $app) {
                Write-LabWarn "Aplicación '$appNombre' no encontrada para credencial; se omite."
                continue
            }
            if ($app -is [array]) { $app = $app[0] }

            # --- 3. Comprobar si la credencial ya existe ---
            $credencialesExistentes = @()
            if ($app.PasswordCredentials) { $credencialesExistentes = @($app.PasswordCredentials) }

            $yaExiste = $false
            foreach ($pc in $credencialesExistentes) {
                if ($pc.DisplayName -eq $displayName) { $yaExiste = $true; break }
            }

            if ($yaExiste) {
                Write-Verbose "   -> Credencial '$displayName' ya existe en '$appNombre' (reutilizada)"
                $creados += [pscustomobject]@{
                    tipo          = 'CredencialApp'
                    aplicacion    = $appNombre
                    displayName   = $displayName
                    appId         = $app.AppId
                    estadoDetalle = 'reutilizado'
                }
                continue
            }

            # --- 4. Crear la credencial ---
            $endDateTime = if ($c.PSObject.Properties['endDateTime'] -and $null -ne $c.endDateTime) {
                [datetime]$c.endDateTime
            } else {
                (Get-Date).AddYears(1)
            }

            $passwordCred = @{
                displayName = $displayName
                endDateTime = $endDateTime
            }

            try {
                $resultado = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential $passwordCred -ErrorAction Stop
            } catch {
                Write-LabWarn "No se pudo crear la credencial '$displayName' en '$appNombre': $($_.Exception.Message)"
                continue
            }

            # El secreto solo se devuelve aquí. No se guarda en el manifiesto.
            $secreto = $resultado.SecretText
            $keyId = $resultado.KeyId

            Write-Verbose "   -> Credencial '$displayName' creada en '$appNombre'"

            # Acumular para mostrar al final (una sola vez)
            if (-not $secretosMostrados.ContainsKey($appNombre)) {
                $secretosMostrados[$appNombre] = @()
            }
            $secretosMostrados[$appNombre] += [pscustomobject]@{
                displayName = $displayName
                keyId       = $keyId
                secreto     = $secreto
                expira      = $endDateTime
            }

            $creados += [pscustomobject]@{
                tipo          = 'CredencialApp'
                aplicacion    = $appNombre
                displayName   = $displayName
                appId         = $app.AppId
                keyId         = $keyId
                estadoDetalle = 'creado'
            }
        }

        # Mostrar secretos UNA SOLA VEZ
        if ($secretosMostrados.Count -gt 0) {
            Write-Host ''
            Write-Host '=== CLIENT SECRETS CREADOS (MOSTRAR UNA SOLA VEZ) ===' -ForegroundColor Yellow
            Write-Host 'Anota estos secretos. NO se guardan en el manifiesto ni se pueden recuperar.' -ForegroundColor Yellow
            Write-Host ''
            foreach ($appNombre in $secretosMostrados.Keys) {
                Write-Host "  Aplicación: $appNombre" -ForegroundColor Cyan
                foreach ($s in $secretosMostrados[$appNombre]) {
                    Write-Host "    DisplayName : $($s.displayName)"
                    Write-Host "    KeyId       : $($s.keyId)"
                    Write-Host "    Secreto     : $($s.secreto)" -ForegroundColor Green
                    Write-Host "    Expira      : $($s.expira.ToString('yyyy-MM-dd'))"
                }
                Write-Host ''
            }
            Write-Host 'Si pierdes un secreto, tendrás que crear una credencial nueva.' -ForegroundColor Yellow
            Write-Host ''
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -ne 'CredencialApp') { return $false }

        $appId = if ($Objeto.datos) { $Objeto.datos.appId } else { $null }
        $keyId = if ($Objeto.datos) { $Objeto.datos.keyId } else { $null }

        # Si no hay keyId (preexistente o reutilizado), no hay nada que revertir
        if ([string]::IsNullOrWhiteSpace($keyId)) {
            return $true
        }

        # Buscar la app por appId
        try {
            $app = $null
            if ($appId) {
                $app = Get-MgApplication -Filter "appId eq '$appId'" -ErrorAction SilentlyContinue
            }
            if (-not $app) { return $true }  # idempotente
            if ($app -is [array]) { $app = $app[0] }

            # Comprobar que la credencial existe
            $credenciales = @()
            if ($app.PasswordCredentials) { $credenciales = @($app.PasswordCredentials) }

            $existe = $false
            foreach ($pc in $credenciales) {
                if ($pc.KeyId -eq $keyId) { $existe = $true; break }
            }
            if (-not $existe) { return $true }  # idempotente

            $null = Remove-MgApplicationPassword -ApplicationId $app.Id -KeyId $keyId -Confirm:$false -ErrorAction Stop
            return $true
        } catch {
            Write-LabWarn "No se pudo revocar la credencial '$($Objeto.id)': $($_.Exception.Message)"
            return $false
        }
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nueva credencial de aplicación (client secret)'

        $appNombre = Read-Host '  Aplicación (displayName)'
        if ([string]::IsNullOrWhiteSpace($appNombre)) {
            Write-LabWarn 'Aplicación vacía. Cancelando.'
            return $null
        }

        # Snapshot pre-lab
        if ($Contexto.SnapshotPreLab -and
            $Contexto.SnapshotPreLab.ContainsKey('aplicaciones') -and
            $Contexto.SnapshotPreLab.aplicaciones.ContainsKey($appNombre)) {
            Write-LabWarn "La aplicación '$appNombre' es preexistente. No se pueden añadir credenciales."
            return $null
        }

        $displayName = Read-Host '  DisplayName de la credencial'
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            Write-LabWarn 'DisplayName vacío. Cancelando.'
            return $null
        }

        $dias = Read-Host '  Días hasta expirar [365]'
        if ([string]::IsNullOrWhiteSpace($dias) -or -not ($dias -match '^\d+$')) {
            $dias = 365
        }

        return [pscustomobject]@{
            aplicacion  = $appNombre
            displayName = $displayName
            endDateTime = (Get-Date).AddDays([int]$dias)
        }
    }
}

Register-LabCapacidad -Capacidad $Capacidad
