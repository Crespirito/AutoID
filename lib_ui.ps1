<#
.SYNOPSIS
    Librería de helpers de consola para el laboratorio.
.DESCRIPTION
    Proporciona:
      - Limpieza de pantalla con fallback (ISE, hosts sin RawUI)
      - Pausa con fallback
      - Cabecera y banner
      - Wrappers de color para mensajes (Info, Ok, Warn, Error)
      - Confirmación explícita por teclado ('SI')

    Es la base del resto de librerías del laboratorio: lib_graph.ps1,
    lib_config.ps1, lib_manifiesto.ps1 y lib_log.ps1 asumen que estas
    funciones existen.
.NOTES
    Sin dependencias. Se carga por dot-sourcing.
    Guardar este fichero como UTF-8 con BOM para compatibilidad con PS 5.1.
#>
#Requires -Version 5.1

# ============================================================
# PANTALLA
# ============================================================

function Clear-LabScreen {
    <#
    .SYNOPSIS
        Limpia la consola de forma segura.
    .DESCRIPTION
        Clear-Host falla en algunos hosts (ISE sin RawUI, redirecciones).
        Se captura y se ignora.
    #>
    try { Clear-Host } catch { }
}

function Wait-LabKey {
    <#
    .SYNOPSIS
        Pausa hasta que el usuario pulse una tecla o Enter.
    .PARAMETER Mensaje
        Texto mostrado antes de la pausa.
    #>
    param(
        [string]$Mensaje = "Pulsa cualquier tecla para continuar..."
    )

    Write-Host ""
    Write-Host $Mensaje -ForegroundColor Gray

    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        # Fallback para hosts sin RawUI (ISE, VS Code terminal en algunos casos)
        $null = Read-Host "(Enter para continuar)"
    }
}

# ============================================================
# CABECERAS Y BANNERS
# ============================================================

function Show-LabHeader {
    <#
    .SYNOPSIS
        Limpia la pantalla y dibuja la cabecera del laboratorio.
    .PARAMETER Titulo
        Título a mostrar. Por defecto, el genérico del laboratorio.
    #>
    param(
        [string]$Titulo = "GESTOR DE ENTORNOS DE LABORATORIO - ENTRA ID (FREE)"
    )

    Clear-LabScreen
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ("    " + $Titulo).PadRight(60) -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-LabBanner {
    <#
    .SYNOPSIS
        Dibuja un separador con un texto de sección.
    .PARAMETER Texto
        Texto de la sección.
    #>
    param(
        [string]$Texto
    )

    Write-Host ""
    Write-Host "--- $Texto ---" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================
# MENSAJES CON COLOR
# ============================================================

function Write-LabInfo {
    <#
    .SYNOPSIS
        Mensaje informativo (gris).
    #>
    param([string]$Msg)
    Write-Host "[INFO]  $Msg" -ForegroundColor Gray
}

function Write-LabOk {
    <#
    .SYNOPSIS
        Mensaje de éxito (verde).
    #>
    param([string]$Msg)
    Write-Host "[OK]    $Msg" -ForegroundColor Green
}

function Write-LabWarn {
    <#
    .SYNOPSIS
        Mensaje de aviso (amarillo).
    #>
    param([string]$Msg)
    Write-Host "[WARN]  $Msg" -ForegroundColor Yellow
}

function Write-LabError {
    <#
    .SYNOPSIS
        Mensaje de error (rojo).
    #>
    param([string]$Msg)
    Write-Host "[ERROR] $Msg" -ForegroundColor Red
}

# ============================================================
# CONFIRMACIONES
# ============================================================

function Read-LabConfirm {
    <#
    .SYNOPSIS
        Pide confirmación explícita escribiendo 'SI'.
    .PARAMETER Mensaje
        Texto de la pregunta.
    .OUTPUTS
        $true si el usuario escribió exactamente 'SI', $false en caso contrario.
    #>
    param(
        [string]$Mensaje = "¿Quieres continuar?"
    )

    Write-Host $Mensaje -ForegroundColor Yellow
    $resp = Read-Host "Escribe 'SI' para confirmar"
    return ($resp -eq "SI")
}