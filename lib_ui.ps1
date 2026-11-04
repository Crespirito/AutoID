<#
.SYNOPSIS
    Librería de helpers de consola para el laboratorio.
.DESCRIPTION
    Proporciona:
      - Limpieza de pantalla con fallback (ISE, hosts sin RawUI)
      - Pausa con fallback
      - Cabecera y banner
      - Wrappers de color para mensajes (Info, Ok, Warn, Error)
      - Confirmación explícita por "SI"
.NOTES
    Sin dependencias. Se carga por dot-sourcing.
    El resto de librerías y scripts asumen que estas funciones existen.

    SOBRE PSAvoidUsingWriteHost:
    Este archivo es el wrapper de UI del laboratorio. El uso de
    Write-Host es INTENCIONAL: es la capa que traduce los mensajes
    del dominio (info, ok, warn, error) a salida de consola con color.
    Las reglas de PSScriptAnalyzer sobre Write-Host se pueden suprimir
    para este archivo sin afectar al resto del proyecto.
#>

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
        [string]$Mensaje = 'Pulsa cualquier tecla para continuar...'
    )

    Write-Host ''
    Write-Host $Mensaje -ForegroundColor Gray

    try {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        # Fallback para hosts sin RawUI (ISE, VS Code terminal en algunos casos)
        $null = Read-Host '(Enter para continuar)'
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
        [string]$Titulo = 'GESTOR DE ENTORNOS DE LABORATORIO - ENTRA ID (FREE)'
    )

    Clear-LabScreen
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ('    ' + $Titulo).PadRight(60) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
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

    Write-Host ''
    Write-Host "--- $Texto ---" -ForegroundColor Cyan
    Write-Host ''
}

# ============================================================
# MENSAJES CON COLOR
# ============================================================

function Write-LabInfo {
    <#
    .SYNOPSIS
        Mensaje informativo (gris).
    .PARAMETER Msg
        Texto del mensaje.
    #>
    param([string]$Msg)
    Write-Host "[INFO]  $Msg" -ForegroundColor Gray
}

function Write-LabOk {
    <#
    .SYNOPSIS
        Mensaje de éxito (verde).
    .PARAMETER Msg
        Texto del mensaje.
    #>
    param([string]$Msg)
    Write-Host "[OK]    $Msg" -ForegroundColor Green
}

function Write-LabWarn {
    <#
    .SYNOPSIS
        Mensaje de aviso (amarillo).
    .PARAMETER Msg
        Texto del mensaje.
    #>
    param([string]$Msg)
    Write-Host "[WARN]  $Msg" -ForegroundColor Yellow
}

function Write-LabError {
    <#
    .SYNOPSIS
        Mensaje de error (rojo).
    .PARAMETER Msg
        Texto del mensaje.
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
        [string]$Mensaje = '¿Quieres continuar?'
    )

    Write-Host $Mensaje -ForegroundColor Yellow
    $resp = Read-Host "Escribe 'SI' para confirmar"
    return ($resp -eq 'SI')
}