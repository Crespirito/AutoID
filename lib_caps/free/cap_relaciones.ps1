<#
.SYNOPSIS
    Capacidad: Relaciones entre objetos.
.DESCRIPTION
    Gestiona las relaciones entre objetos del laboratorio a partir de la
    sección 'relaciones' del escenario.

    TIPOS SOPORTADOS:
      - membresia: usuario -> grupo (New-MgGroupMemberByRef)

    SEGURIDAD DE PREEXISTENTES:
    - Si el grupo es preexistente (snapshot pre-lab), la membresía no se
      aplica y se marca 'preexistente'.
    - Si la membresía ya existía, se marca 'reutilizado'.

    DEPENDENCIAS: Usuarios, Grupos.
    NIVEL: Free.
.NOTES
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

$Capacidad = @{
    Nombre      = 'Relaciones'
    Descripcion = 'Relaciones entre objetos'
    SeccionJson = 'relaciones'
    Alias       = @('Relaciones')
    Nivel       = 'Free'
    DependeDe   = @('Usuarios','Grupos')
    PermisosApp = @('Group.ReadWrite.All','User.Read.All')

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
        $tiposSoportados = @('membresia')
        foreach ($r in @($Def)) {
            $i++
            $tipo = if ($r.PSObject.Properties['tipo']) { $r.tipo } else { $null }
            
            if ([string]::IsNullOrWhiteSpace($tipo)) {
                $errores += "Relación #$i sin 'tipo'."
                continue
            }
            if ($tipo -notin $tiposSoportados) {
                $errores += "Relación #$i con tipo no soportado: '$tipo'. Soportados: $($tiposSoportados -join ', ')."
                continue
            }
            if ($tipo -eq 'membresia') {
                if ([string]::IsNullOrWhiteSpace($r.usuario)) {
                    $errores += "Relación #$i de tipo 'membresia' sin 'usuario'."
                }
                if ([string]::IsNullOrWhiteSpace($r.grupo)) {
                    $errores += "Relación #$i de tipo 'membresia' sin 'grupo'."
                }
            }
        }
        return $errores
    }

    Describir = {
        param($Def)
        $porTipo = @{}
        foreach ($r in @($Def)) {
            $tipo = if ($r.PSObject.Properties['tipo']) { $r.tipo } else { 'Desconocido' }
            if (-not $porTipo.ContainsKey($tipo)) { $porTipo[$tipo] = 0 }
            $porTipo[$tipo]++
        }
        $lineas = @()
        foreach ($t in $porTipo.Keys) {
            $lineas += "$t ($($porTipo[$t]))"
        }
        return "Relaciones ($(@($Def).Count)): $($lineas -join ', ')"
    }

    Crear = {
        param($Def, $Contexto)

        $creados = @()

        foreach ($r in @($Def)) {
            $tipo = if ($r.PSObject.Properties['tipo']) { $r.tipo } else { '' }

            switch ($tipo) {
                'membresia' {
                    $upn = $r.usuario -replace '\{tenant\}', $Contexto.TenantDomain
                    $nombreGrupo = $r.grupo

                    # Snapshot pre-lab: si el grupo es preexistente, no se toca
                    if ($Contexto.SnapshotPreLab -and
                        $Contexto.SnapshotPreLab.ContainsKey('grupos') -and
                        $Contexto.SnapshotPreLab.grupos.ContainsKey($nombreGrupo)) {
                        Write-LabWarn "Grupo '$nombreGrupo' es preexistente. Membresía de '$upn' no se aplica."
                        $creados += [pscustomobject]@{
                            tipo          = 'MembresiaGrupo'
                            upn           = $upn
                            grupo         = $nombreGrupo
                            estadoDetalle = 'preexistente'
                        }
                        continue
                    }

                    # Buscar usuario
                    $usuario = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
                    if (-not $usuario) {
                        Write-LabWarn "Usuario '$upn' no encontrado para membresía; se omite."
                        continue
                    }
                    if ($usuario -is [array]) { $usuario = $usuario[0] }

                    # Buscar grupo (N14: escapado OData)
                    $nombreGrupoEscapado = $nombreGrupo -replace "'","''"
                    $grupo = Get-MgGroup -Filter "displayName eq '$nombreGrupoEscapado'" -ErrorAction SilentlyContinue
                    if (-not $grupo) {
                        Write-LabWarn "Grupo '$nombreGrupo' no encontrado para membresía; se omite."
                        continue
                    }
                    if ($grupo -is [array]) { $grupo = $grupo[0] }

                    # Comprobar si ya es miembro
                    $miembros = Get-MgGroupMember -GroupId $grupo.Id -All -ErrorAction SilentlyContinue
                    $yaEsMiembro = $false
                    foreach ($m in @($miembros)) {
                        if ($m.Id -eq $usuario.Id) { $yaEsMiembro = $true; break }
                    }
                    
                    if ($yaEsMiembro) {
                        Write-Verbose "   -> $upn ya es miembro de $nombreGrupo"
                        $estadoDetalle = 'reutilizado'
                    } else {
                        $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($usuario.Id)" }
                        $null = New-MgGroupMemberByRef -GroupId $grupo.Id -BodyParameter $body -ErrorAction Stop
                        Write-Verbose "   -> $upn añadido a $nombreGrupo"
                        $estadoDetalle = 'creado'
                    }

                    $creados += [pscustomobject]@{
                        tipo          = 'MembresiaGrupo'
                        groupId       = $grupo.Id
                        userId        = $usuario.Id
                        upn           = $upn
                        grupo         = $nombreGrupo
                        estadoDetalle = $estadoDetalle
                    }
                }
                default {
                    Write-LabWarn "Tipo de relación no soportado: '$tipo'. Se omite."
                }
            }
        }

        return $creados
    }

    Revertir = {
        param($Objeto, $Contexto)

        if ($Objeto.tipo -eq 'MembresiaGrupo') {
            $groupId = if ($Objeto.datos) { $Objeto.datos.groupId } else { $null }
            $userId  = if ($Objeto.datos) { $Objeto.datos.userId }  else { $null }

            if (-not $groupId -or -not $userId) {
                return $true
            }

            try {
                $null = Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $userId -Confirm:$false -ErrorAction Stop
                return $true
            } catch {
                if ($_.Exception.Message -match '404|not found|does not exist') { return $true }
                Write-LabWarn "No se pudo quitar la membresía $userId -> $groupId : $($_.Exception.Message)"
                return $false
            }
        }

        return $false
    }

    PreguntarUI = {
        param($Contexto)

        Show-LabBanner 'Nueva relación'

        Write-Host '  Tipos disponibles:' -ForegroundColor Cyan
        Write-Host '    [1] membresia (usuario -> grupo)'
        $op = Read-Host '  Opción [1]'

        if ($op -ne '1') { return $null }

        $upn = Read-Host '  UPN del usuario'
        if ([string]::IsNullOrWhiteSpace($upn)) { return $null }

        $grupo = Read-Host '  DisplayName del grupo'
        if ([string]::IsNullOrWhiteSpace($grupo)) { return $null }

        return [pscustomobject]@{
            tipo    = 'membresia'
            usuario = $upn
            grupo   = $grupo
        }
    }
}

$null = Register-LabCapacidad -Capacidad $Capacidad