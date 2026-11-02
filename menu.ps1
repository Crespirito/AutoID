<#
.SYNOPSIS
    Menú orquestador para entornos de laboratorio en Entra ID (Free).
.DESCRIPTION
    Gestiona la sesión de Microsoft Graph (persistente hasta salir con 0),
    la configuración y el manifiesto, y delega la creación/limpieza en
    los scripts hijos:
      - creauto.ps1
      - creamanual.ps1
      - clean_up.ps1

    La conexión a Graph se realiza al arrancar. Si hay datos de App-Only
    guardados en la configuración, se usan. Si no, se intenta el flujo
    interactivo.
.NOTES
    Requiere que estén presentes en la misma carpeta:
      lib_ui.ps1, lib_config.ps1, lib_graph.ps1, lib_manifiesto.ps1, lib_log.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# VALIDACIÓN DE CONTEXTO
# ============================================================
if (-not $PSScriptRoot) {
    throw "Ejecuta este script como archivo .ps1, no pegado en consola."
}

# ============================================================
# CARGA DE LIBRERÍAS (orden importante)
# ============================================================
. (Join-Path $PSScriptRoot "lib_ui.ps1")
. (Join-Path $PSScriptRoot "lib_config.ps1")   # Antes de graph para que Get-LabConfig exista
. (Join-Path $PSScriptRoot "lib_graph.ps1")
. (Join-Path $PSScriptRoot "lib_manifiesto.ps1")
. (Join-Path $PSScriptRoot "lib_log.ps1")

# ============================================================
# RUTAS A LOS SCRIPTS HIJOS
# ============================================================
$ScriptAuto    = Join-Path $PSScriptRoot "creauto.ps1"
$ScriptManual  = Join-Path $PSScriptRoot "creamanual.ps1"
$ScriptCleanup = Join-Path $PSScriptRoot "clean_up.ps1"

# ============================================================
# ESTADO DEL MENÚ
# ============================================================
$script:config = Get-LabConfig

# ============================================================
# FUNCIONES AUXILIARES
# ============================================================

function Invoke-EnsureSession {
    if (Test-LabGraphSession) { return $true }
    Write-LabWarn "No hay sesión de Graph activa. Conectando..."
    return (Connect-LabGraph)
}

function Test-ScriptHijo {
    param([string]$Path, [string]$Nombre)
    if (-not (Test-Path $Path)) {
        Write-LabError "No se encuentra el script '$Nombre' en: $Path"
        return $false
    }
    return $true
}

function Invoke-ScriptHijo {
    param(
        [string]$Path,
        [hashtable]$Argumentos
    )

    Write-Host ""
    Write-Host "Ejecutando: $(Split-Path $Path -Leaf)" -ForegroundColor Green
    Write-Host "------------------------------------------------------------" -ForegroundColor Gray

    $exitCode = 0
    try {
        & $Path @Argumentos
        if ($null -ne $LASTEXITCODE) { $exitCode = $LASTEXITCODE }
    } catch {
        Write-LabError "Fallo durante la ejecución: $($_.Exception.Message)"
        $exitCode = 1
    }

    if ($exitCode -ne 0) {
        Write-LabWarn "El script finalizó con código $exitCode."
    }

    Write-Host "------------------------------------------------------------" -ForegroundColor Gray
}

# ============================================================
# ACCIONES DEL MENÚ
# ============================================================

function Invoke-GestionSesion {
    Show-LabHeader -Titulo "GESTION DE SESION DE GRAPH"
    
    $status = Get-LabGraphStatus
    $config = Get-LabConfig

    if ($status) {
        Write-LabOk "Sesión activa."
        Write-Host "  Usuario : $($status.Account)"
        Write-Host "  Tenant  : $($status.TenantId)"
        Write-Host "  Scopes  : $($status.Scopes)"
    } else {
        Write-LabWarn "No hay sesión activa."
    }
    Write-Host ""

    # --- Opciones de gestión ---
    Write-Host "  [1] Reconectar (cerrar y abrir sesión)"
    Write-Host "  [2] Introducir datos App-Only (Certificado)"
    Write-Host "  [V] Volver al menú principal"
    Write-Host ""

    $op = Read-Host "Selecciona una opción"

    switch ($op.ToUpper()) {
        "1" {
            $null = Connect-LabGraph -Forzar
            Wait-LabKey
        }
        "2" {
            Write-Host ""
            Write-Host "Introduce los datos de la App-Only (deja en blanco para borrar):" -ForegroundColor Yellow
            
            $newClientId = Read-Host "  Client ID [$($config.AppOnlyClientId)]"
            if ([string]::IsNullOrWhiteSpace($newClientId)) { $newClientId = $null }
            
            $newTenantId = Read-Host "  Tenant ID [$($config.AppOnlyTenantId)]"
            if ([string]::IsNullOrWhiteSpace($newTenantId)) { $newTenantId = $null }
            
            $newThumbprint = Read-Host "  Thumbprint [$($config.AppOnlyThumbprint)]"
            if ([string]::IsNullOrWhiteSpace($newThumbprint)) { $newThumbprint = $null }
            
            $newCertName = Read-Host "  Nombre del certificado (opcional) [$($config.AppOnlyCertName)]"
            if ([string]::IsNullOrWhiteSpace($newCertName)) { $newCertName = $null }

            $config.AppOnlyClientId   = $newClientId
            $config.AppOnlyTenantId   = $newTenantId
            $config.AppOnlyThumbprint = $newThumbprint
            $config.AppOnlyCertName   = $newCertName
            
            $null = Save-LabConfig -Config $config
            Write-LabOk "Datos App-Only guardados en menu_config.json."
            Wait-LabKey
        }
        default {
            # "V" o cualquier otra tecla vuelve al menú
        }
    }
}

function Invoke-GestionModulosGraph {
    while ($true) {
        Show-LabHeader -Titulo "GESTION DE MODULOS DE GRAPH"
        
        $infoModulos = Get-LabGraphModulosInfo
        Write-Host "Estado de los módulos:" -ForegroundColor Cyan
        
        for ($i = 0; $i -lt $infoModulos.Count; $i++) {
            $m = $infoModulos[$i]
            $estado = ""
            if ($m.Cargado)       { $estado = "[CARGADO]" -ForegroundColor Green }
            elseif ($m.Instalado) { $estado = "[INSTALADO]" -ForegroundColor Yellow }
            else                  { $estado = "[NO INSTALADO]" -ForegroundColor DarkGray }
            
            Write-Host ("  [{0}] {1,-45} {2}" -f ($i + 1), $m.Descripcion, $estado)
        }
        
        Write-Host ""
        Write-Host "  [I] Instalar TODOS los de la lista"
        Write-Host "  [C] Cargar TODOS los instalados"
        Write-Host "  [V] Volver al menu principal"
        Write-Host ""
        
        $opcion = Read-Host "Selecciona un módulo para instalar/cargar, o una opción"
        
        if ($opcion.ToUpper() -eq "V") { return }
        
        if ($opcion.ToUpper() -eq "I") {
            $todos = $script:LabGraphCatalogo.Keys
            $null = Install-LabGraphModules -Modulos $todos
            $null = Import-LabGraphModules -Modulos $todos
            Write-LabOk "Todos los módulos preparados."
            Wait-LabKey
            continue
        }

        if ($opcion.ToUpper() -eq "C") {
            $instalados = ($infoModulos | Where-Object { $_.Instalado }).Nombre
            $null = Import-LabGraphModules -Modulos $instalados
            Write-LabOk "Módulos instalados cargados en memoria."
            Wait-LabKey
            continue
        }
        
        if ($opcion -match '^\d+$') {
            $idx = [int]$opcion - 1
            if ($idx -ge 0 -and $idx -lt $infoModulos.Count) {
                $modElegido = $infoModulos[$idx]
                Write-Host ""
                Write-Host "Has seleccionado: $($modElegido.Nombre)" -ForegroundColor Yellow
                
                $null = Install-LabGraphModules -Modulos @($modElegido.Nombre)
                $null = Import-LabGraphModules -Modulos @($modElegido.Nombre)
                
                Write-LabOk "Módulo preparado: $($modElegido.Nombre)"
                Wait-LabKey
            } else {
                Write-LabWarn "Número fuera de rango."
                Start-Sleep -Seconds 1
            }
        } else {
            Write-LabWarn "Opción no válida."
            Start-Sleep -Seconds 1
        }
    }
}

function Invoke-CrearAutomatica {
    if (-not (Test-ScriptHijo -Path $ScriptAuto -Nombre "creauto.ps1")) {
        Wait-LabKey; return
    }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (Test-LabManifiestoExists) {
        Write-LabWarn "Ya existe un manifiesto pendiente. Se sobrescribirá si creas un nuevo entorno."
        $resp = Read-Host "Escribe 'SI' para continuar"
        if ($resp -ne "SI") {
            Write-LabInfo "Operación cancelada."
            Start-Sleep -Seconds 1
            return
        }
    }

    $argumentos = @{}
    if ($script:config.Verbose) { $argumentos["Verbose"] = $true }

    Invoke-ScriptHijo -Path $ScriptAuto -Argumentos $argumentos
    Wait-LabKey
}

function Invoke-CrearPersonalizada {
    if (-not (Test-ScriptHijo -Path $ScriptManual -Nombre "creamanual.ps1")) {
        Wait-LabKey; return
    }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (Test-LabManifiestoExists) {
        Write-LabWarn "Ya existe un manifiesto pendiente. Se sobrescribirá si creas un nuevo entorno."
        $resp = Read-Host "Escribe 'SI' para continuar"
        if ($resp -ne "SI") {
            Write-LabInfo "Operación cancelada."
            Start-Sleep -Seconds 1
            return
        }
    }

    $argumentos = @{}
    if ($script:config.Verbose) { $argumentos["Verbose"] = $true }

    Invoke-ScriptHijo -Path $ScriptManual -Argumentos $argumentos
    Wait-LabKey
}

function Invoke-Limpiar {
    if (-not (Test-ScriptHijo -Path $ScriptCleanup -Nombre "clean_up.ps1")) {
        Wait-LabKey; return
    }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (-not (Test-LabManifiestoExists)) {
        Write-LabWarn "No hay manifiesto pendiente. Nada que limpiar."
        Wait-LabKey; return
    }

    $argumentos = @{ ManifiestoPath = (Get-LabManifiestoPath) }
    if ($script:config.Verbose) { $argumentos["Verbose"] = $true }
    Invoke-ScriptHijo -Path $ScriptCleanup -Argumentos $argumentos

    Wait-LabKey
}

function Invoke-VerManifiesto {
    Show-LabHeader -Titulo "MANIFIESTO"

    if (-not (Test-LabManifiestoExists)) {
        Write-LabWarn "No hay manifiesto pendiente."
        Wait-LabKey; return
    }

    try {
        $m = Get-LabManifiesto

        Write-Host "Fecha             : $($m.Fecha)"
        Write-Host "Tenant ID         : $($m.TenantId)"
        Write-Host "Tenant Domain     : $($m.TenantDomain)"
        Write-Host ""

        Write-Host "Usuarios ($($m.Usuarios.Count)):" -ForegroundColor Cyan
        if ($m.Usuarios.Count -gt 0) {
            $m.Usuarios | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host "  (ninguno)" -ForegroundColor DarkGray
        }
        Write-Host ""

        Write-Host "Grupos ($($m.Grupos.Count)):" -ForegroundColor Cyan
        if ($m.Grupos.Count -gt 0) {
            $m.Grupos | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host "  (ninguno)" -ForegroundColor DarkGray
        }
        Write-Host ""

        Write-Host "Aplicaciones ($($m.Aplicaciones.Count)):" -ForegroundColor Cyan
        if ($m.Aplicaciones.Count -gt 0) {
            $m.Aplicaciones | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host "  (ninguna)" -ForegroundColor DarkGray
        }
        Write-Host ""

        Write-Host "Service Principals ($($m.ServicePrincipals.Count)):" -ForegroundColor Cyan
        if ($m.ServicePrincipals.Count -gt 0) {
            $m.ServicePrincipals | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host "  (ninguno)" -ForegroundColor DarkGray
        }
    } catch {
        Write-LabError "No se pudo leer el manifiesto: $($_.Exception.Message)"
    }

    Wait-LabKey
}

function Invoke-ToggleVerbose {
    $script:config.Verbose = -not $script:config.Verbose
    $null = Save-LabConfig -Config $script:config
    Write-LabOk "Modo Verbose: $($script:config.Verbose)"
    Start-Sleep -Seconds 1
}

function Invoke-ResetConfig {
    $script:config = Reset-LabConfig
    Write-LabOk "Configuración reseteada a valores por defecto."
    Start-Sleep -Seconds 1
}

function Invoke-InfoLicencia {
    Show-LabHeader -Titulo "INFORMACION - TENANT FREE"

    Write-Host "Esta versión está adaptada a tenants Microsoft Entra ID Free." -ForegroundColor White
    Write-Host ""

    Write-Host "Disponible en Free:" -ForegroundColor Green
    Write-Host "  - Creación de usuarios"
    Write-Host "  - Creación de grupos de seguridad"
    Write-Host "  - Creación de aplicaciones y service principals"
    Write-Host "  - Asignación de miembros a grupos"
    Write-Host "  - Asignación de propietarios a service principals"
    Write-Host "  - Añadir credenciales a aplicaciones"
    Write-Host ""

    Write-Host "NO disponible en Free (requiere P1/P2):" -ForegroundColor Red
    Write-Host "  - Asignación de roles de directorio"
    Write-Host "  - Grupos con asignación de roles"
    Write-Host "  - Grupos dinámicos"
    Write-Host "  - Acceso condicional avanzado"
    Write-Host "  - Gestión de PIM"

    Wait-LabKey
}

# ============================================================
# PANTALLAS DE ESTADO
# ============================================================

function Show-EstadoSesion {
    Write-Host "--- Sesion Graph ---" -ForegroundColor Yellow
    $s = Get-LabGraphStatus
    if ($s) {
        Write-Host "  Conectado : $($s.Account)" -ForegroundColor Green
        Write-Host "  Tenant    : $($s.TenantId)"
    } else {
        Write-Host "  Sin sesion activa" -ForegroundColor Red
    }
    
    # Mostrar si hay datos App-Only configurados
    $config = Get-LabConfig
    if ($config.AppOnlyClientId) {
        Write-Host "  App-Only  : Configurado (Client ID: $($config.AppOnlyClientId))" -ForegroundColor DarkGray
    } else {
        Write-Host "  App-Only  : No configurado" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Show-EstadoConfig {
    Write-Host "--- Configuracion ---" -ForegroundColor Yellow
    Write-Host "  Verbose   : $($script:config.Verbose)"
    Write-Host ""
}

function Show-EstadoManifiesto {
    Write-Host "--- Manifiesto ---" -ForegroundColor Yellow
    $m = Get-LabManifiestoStatus
    if ($null -eq $m) {
        Write-Host "  Sin manifiesto pendiente" -ForegroundColor DarkGray
    } elseif ($m -eq "ilegible") {
        Write-Host "  Manifiesto presente pero ilegible" -ForegroundColor Red
    } else {
        Write-Host "  Fecha     : $($m.Fecha)"
        Write-Host "  Tenant    : $($m.Tenant)"
        Write-Host "  Usuarios  : $($m.Usuarios) | Grupos: $($m.Grupos) | Apps: $($m.Apps)"
    }
    Write-Host ""
}

# ============================================================
# ARRANQUE: CONEXIÓN INICIAL A GRAPH
# ============================================================
Show-LabHeader -Titulo "GESTOR DE ENTORNOS DE LABORATORIO - ENTRA ID (FREE)"

Write-LabInfo "Iniciando sesión de Microsoft Graph..."
if (-not (Connect-LabGraph)) {
    Write-LabError "No se pudo establecer la sesión inicial."
    Write-LabWarn "El menú arrancará sin sesión. Usa la opción [C] para configurar o conectar manualmente."
    Wait-LabKey
}

# ============================================================
# BUCLE PRINCIPAL
# ============================================================
while ($true) {
    Show-LabHeader
    Show-EstadoSesion
    Show-EstadoConfig
    Show-EstadoManifiesto

    Write-Host "--- Creacion ---" -ForegroundColor Cyan
    Write-Host "  [1] Creacion automatica"
    Write-Host "  [2] Creacion personalizada"
    Write-Host ""
    Write-Host "--- Limpieza ---" -ForegroundColor Cyan
    Write-Host "  [3] Limpiar entorno"
    Write-Host ""
    Write-Host "--- Manifiesto ---" -ForegroundColor Cyan
    Write-Host "  [4] Ver manifiesto"
    Write-Host ""
    Write-Host "--- Sesion / Configuracion ---" -ForegroundColor Cyan
    Write-Host "  [C] Gestionar sesion de Graph"
    Write-Host "  [M] Gestionar modulos de Graph"
    Write-Host "  [V] Alternar Verbose"
    Write-Host "  [R] Resetear configuracion"
    Write-Host "  [I] Info sobre tenant Free"
    Write-Host ""
    Write-Host "  [0] Salir"
    Write-Host ""

    $opcion = Read-Host "Selecciona una opcion"

    switch ($opcion.ToUpper()) {
        "1" { Invoke-CrearAutomatica }
        "2" { Invoke-CrearPersonalizada }
        "3" { Invoke-Limpiar }
        "4" { Invoke-VerManifiesto }
        "C" { Invoke-GestionSesion }
        "M" { Invoke-GestionModulosGraph }
        "V" { Invoke-ToggleVerbose }
        "R" { Invoke-ResetConfig }
        "I" { Invoke-InfoLicencia }
        "0" {
            $null = Save-LabConfig -Config $script:config
            Disconnect-LabGraph
            Write-Host ""
            Write-LabOk "Sesión cerrada. Saliendo..."
            exit 0
        }
        default {
            Write-LabError "Opcion no valida."
            Start-Sleep -Seconds 1
        }
    }
}