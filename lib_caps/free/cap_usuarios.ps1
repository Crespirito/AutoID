<#
.SYNOPSIS
    Capacidad: Usuarios.
.DESCRIPTION
    Crea usuarios en Entra ID a partir de una sección 'usuarios' del
    escenario. Respeta el snapshot pre-lab: si el UPN ya existía antes
    del laboratorio, no lo adopta ni lo modifica.

    CONTRASEÑAS:
    El JSON del escenario NO contiene contraseñas. Las contraseñas se
    reciben a través de $Contexto.PasswordsPorUpn (hashtable upn -> string),
    que creauto.ps1 rellena con las contraseñas derivadas de la semilla
    antes de llamar a Crear.

    SEGURIDAD DE PREEXISTENTES:
    - Si el UPN está en $Contexto.SnapshotPreLab.usuarios, el usuario
      existía antes del lab. Se devuelve estadoDetalle = 'preexistente'
      y no se modifica.
    - Si el UPN no está en el snapshot pero existe en el tenant, fue
      creado por una ejecución anterior del lab. Se reutiliza y se marca
      'reutilizado'.
    - Si no existe, se crea y se marca 'creado'.

    NIVEL: Free.
#>

$Capacidad = @{
    Nombre      = 'Usuarios'
    SeccionJson = 'usuarios'
    Alias       = @('Usuarios')
    Nivel       = 'Free'
    DependeDe   = @()
    PermisosApp = @('User.ReadWrite.All')

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
        foreach ($u in @($Def)) {
            $i++
            if ([string]::IsNullOrWhiteSpace($u.displayName)) {
                $errores += "Usuario #$i sin 'displayName'."
            }
            if ([string]::IsNullOrWhiteSpace($u.upn)) {
                $errores += "Usuario #$i sin 'upn'."
            } elseif ($u.upn -notmatch '@') {
                $errores += "Usuario #$i con 'upn' inválido: '$($u.upn)'."
            }
            if ([string]::IsNullOrWhiteSpace($u.mailNickname)) {
                $errores += "Usuario #$i sin 'mailNickname'."
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $nombres = @($Def) | ForEach-Object { $_.displayName }
        return "Usuarios ($($nombres.Count)): $($nombres -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($u in @($Def)) {
            $upnOriginal = $u.upn
            $upn = $u.upn -replace '\{tenant\}', $Contexto.TenantDomain
            $displayName = $u.displayName
            $mailNickname = $u.mailNickname
            $department = if ($u.PSObject.Properties['department']) { $u.department } else { '' }
            $jobTitle   = if ($u.PSObject.Properties['jobTitle'])   { $u.jobTitle }   else { '' }

            # --- 1. Comprobar snapshot pre-lab ---
            $upnKey = $upn.ToLowerInvariant()
            if ($Contexto.SnapshotPreLab -and
                $Contexto.SnapshotPreLab.ContainsKey('usuarios') -and
                $Contexto.SnapshotPreLab.usuarios.ContainsKey($upnKey)) {
                Write-LabWarn "Usuario '$upn' ya existía antes del laboratorio. No se adopta ni modifica."
                $creados += [pscustomobject]@{
                    tipo          = 'Usuario'
                    upn           = $upn
                    objectId      = $Contexto.SnapshotPreLab.usuarios[$upnKey]
                    displayName   = $displayName
                    estadoDetalle = 'preexistente'
                }
                continue
            }

            # --- 2. Contraseña ---
            $password = $null
            if ($Contexto.ContainsKey('PasswordsPorUpn') -and $Contexto.PasswordsPorUpn.ContainsKey($upn)) {
                $password = $Contexto.PasswordsPorUpn[$upn]
            } elseif ($Contexto.ContainsKey('PasswordsPorUpn') -and $Contexto.PasswordsPorUpn.ContainsKey($upnOriginal)) {
                $password = $Contexto.PasswordsPorUpn[$upnOriginal]
            }

            if ([string]::IsNullOrWhiteSpace($password)) {
                throw "No hay contraseña para '$upn'. creauto.ps1 debe inyectarla en `$Contexto.PasswordsPorUpn."
            }

            # --- 3. ¿Existe ya en el tenant? ---
            $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
            if ($existing) {
                if ($existing -is [array]) { $existing = $existing[0] }
                Write-Verbose "   -> Usuario existe: $upn (reutilizado, actualizando contraseña)"

                $passwordProfile = @{
                    Password                      = $password
                    ForceChangePasswordNextSignIn = $false
                }
                $null = Update-MgUser -UserId $existing.Id -PasswordProfile $passwordProfile -ErrorAction Stop

                $creados += [pscustomobject]@{
                    tipo          = 'Usuario'
                    upn           = $upn
                    objectId      = $existing.Id
                    displayName   = $displayName
                    estadoDetalle = 'reutilizado'
                }
            } else {
                $params = @{
                    DisplayName       = $displayName
                    UserPrincipalName = $upn
                    MailNickname      = $mailNickname
                    AccountEnabled    = $true
                    PasswordProfile   = @{
                        ForceChangePasswordNextSignIn = $false
                        Password                      = $password
                    }
                }
                if ($department) { $params.Department = $department }
                if ($jobTitle)   { $params.JobTitle   = $jobTitle }

                $user = New-MgUser @params -ErrorAction Stop
                if ($null -eq $user) { throw "New-MgUser no devolvió objeto para $upn" }
                if ($user -is [array]) { $user = $user[0] }

                Write-Verbose "   -> Usuario creado: $upn"
                $creados += [pscustomobject]@{
                    tipo          = 'Usuario'
                    upn           = $upn
                    objectId      = $user.Id
                    displayName   = $displayName
                    estadoDetalle = 'creado'
                }
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        # $Objeto es una entrada del manifiesto:
        # { id, tipo, capacidad, estado, datos: { upn, objectId, displayName } }
        $upn = $null
        $objectIdEsperado = $null
        if ($Objeto.datos) {
            if ($Objeto.datos.PSObject.Properties['upn'])      { $upn = $Objeto.datos.upn }
            if ($Objeto.datos.PSObject.Properties['objectId']) { $objectIdEsperado = $Objeto.datos.objectId }
        }

        if ([string]::IsNullOrWhiteSpace($upn)) {
            Write-LabWarn "Usuario sin upn en el manifiesto: $($Objeto.id)"
            return $false
        }

        try {
            $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
            if (-not $user) {
                # Ya no existe: idempotente
                return $true
            }
            if ($user -is [array]) { $user = $user[0] }

            # Segunda capa de seguridad: verificar objectId
            if (-not [string]::IsNullOrWhiteSpace($objectIdEsperado) -and
                $user.Id -ne $objectIdEsperado) {
                Write-LabWarn "El usuario '$upn' tiene un objectId distinto al del manifiesto. No se borra."
                return $false
            }

            $null = Remove-MgUser -UserId $user.Id -Confirm:$false -ErrorAction Stop
            return $true
        } catch {
            Write-LabWarn "No se pudo borrar el usuario '$upn': $($_.Exception.Message)"
            return $false
        }
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nuevo usuario'

        $displayName = Read-Host '  DisplayName'
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            Write-LabWarn 'DisplayName vacío. Cancelando.'
            return $null
        }

        $nick = $displayName.ToLower() -replace '[^a-z0-9]', '.'
        $upnDefault = "$nick@$($Contexto.TenantDomain)"
        $upn = Read-Host "  UPN [$upnDefault]"
        if ([string]::IsNullOrWhiteSpace($upn)) { $upn = $upnDefault }

        # Comprobar snapshot pre-lab
        $upnKey = $upn.ToLowerInvariant()
        if ($Contexto.SnapshotPreLab -and
            $Contexto.SnapshotPreLab.ContainsKey('usuarios') -and
            $Contexto.SnapshotPreLab.usuarios.ContainsKey($upnKey)) {
            Write-LabWarn "El UPN '$upn' ya existía antes del laboratorio. No se puede adoptar."
            return $null
        }

        $department = Read-Host '  Department (opcional)'
        $jobTitle   = Read-Host '  JobTitle (opcional)'

        # Contraseña: manual o derivada
        Write-Host ''
        Write-Host '  Contraseña:' -ForegroundColor Cyan
        Write-Host '    [1] Introducir manualmente (no se muestra)'
        Write-Host '    [2] Generar automáticamente desde la semilla de la sesión'
        $opPwd = Read-Host '  Opción [1/2]'

        $passwordPlain = $null

        if ($opPwd -eq '2') {
            if (-not $Contexto.ContainsKey('DerivarPassword') -or $Contexto.DerivarPassword -isnot [scriptblock]) {
                Write-LabWarn 'No hay derivador de contraseñas en el contexto. Usa opción manual.'
                return $null
            }
            $passwordPlain = & $Contexto.DerivarPassword $upn
            Write-Host ''
            Write-Host '  Contraseña generada (MOSTRAR UNA SOLA VEZ):' -ForegroundColor Yellow
            Write-Host "    $passwordPlain" -ForegroundColor Gray
            Write-Host '  Anótala. Se puede reproducir conservando la semilla.' -ForegroundColor Yellow
            Write-Host ''
        } else {
            $secure = Read-LabSecureString -Prompt '  Password'
            if ($null -eq $secure) {
                Write-LabWarn 'Password vacía. Cancelando.'
                return $null
            }
            $passwordPlain = ConvertFrom-LabSecureString -SecureString $secure
        }

        if (-not $Contexto.ContainsKey('PasswordsPorUpn')) {
            $Contexto['PasswordsPorUpn'] = @{}
        }
        $Contexto.PasswordsPorUpn[$upn] = $passwordPlain

        $def = [pscustomobject]@{
            displayName  = $displayName
            upn          = $upn
            mailNickname = ($displayName -replace '[^a-zA-Z0-9]', '')
        }
        if ($department) { $def | Add-Member -NotePropertyName department -NotePropertyValue $department }
        if ($jobTitle)   { $def | Add-Member -NotePropertyName jobTitle   -NotePropertyValue $jobTitle }

        return $def
    }
}

Register-LabCapacidad -Capacidad $Capacidad
