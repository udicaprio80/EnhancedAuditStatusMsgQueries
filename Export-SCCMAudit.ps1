# Autore: U. Di Caprio
# Esporta gli SCCM Audit in un file json utilizzando Export-StatusMessagesFixed.ps1 per la descrizione completa.
# il file senza parametri esegue l'export del giorno precedente 
# .\Export-SCCMAudit.ps1 -OutputPath "<path>"
# o specificando una data 
# .\Export-SCCMAudit.ps1 -TargetDate "yyyy-mm-dd" -OutputPath "<path>"
# esegui il comando seguente per verificare il JSON (Sostituisci il percorso con quello reale del tuo file)
# $TestData = Get-Content "D:\Temp\Audit_SCCM\SCCM_Audit_2026-02-03.json" | ConvertFrom-Json
# $TestData | Out-GridView
# Visualizzerai i record in una tabella leggibile
# sostituire nello script il percorso D:\TEMP\Audit_SCCM con uno a vostro piacimento

param(
    [Parameter(Mandatory=$false)]
    [string]$TargetDate = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd"),

    [Parameter(Mandatory=$true)]
    [string]$OutputPath
)

# 1. Configurazione percorsi CSV (D:\TEMP\Audit_SCCM)
$CsvFolder = "D:\TEMP\Audit_SCCM"
$CsvFiles = @("ExportProviderMsgs.csv", "ExportServerMsgs.csv", "ExportClientMsgs.csv")

# 2. Caricamento Dizionario Messaggi dai 3 CSV
$MessageLookup = @{}
foreach ($FileName in $CsvFiles) {
    $FullPath = Join-Path $CsvFolder $FileName
    if (Test-Path $FullPath) {
        Write-Host "Caricamento descrizioni da $FileName..." -ForegroundColor Gray
        $Data = Import-Csv $FullPath
        foreach ($Row in $Data) {
            if ($Row.MessageID -and -not $MessageLookup.ContainsKey($Row.MessageID)) {
                $MessageLookup[$Row.MessageID] = $Row.MessageString
            }
        }
    }
}

# 3. Connessione al Provider SCCM
try {
    $SiteInfo = Get-CimInstance -Namespace "root\SMS" -ClassName "SMS_ProviderLocation" -ErrorAction Stop
    $Namespace = "root\sms\site_$($SiteInfo.SiteCode)"
} catch {
    Write-Error "Impossibile connettersi al Provider SCCM."
    exit
}

# 4. Estrazione Audit Logs
try {
    Write-Host "Estrazione e formattazione Audit per: $TargetDate..." -ForegroundColor Cyan
    
    $Wql = "SELECT * FROM SMS_StatusMessage WHERE Time >= '$TargetDate 00:00:00' AND Time <= '$TargetDate 23:59:59' AND MessageID >= 30000 AND MessageID <= 45000"
    $Messages = Get-CimInstance -Namespace $Namespace -Query $Wql

    if ($null -eq $Messages) {
        Write-Host "Nessun evento trovato." -ForegroundColor Yellow ; exit
    }

    $FinalAuditLog = New-Object System.Collections.Generic.List[PSObject]

    foreach ($Msg in $Messages) {
        $RID = $Msg.RecordID
        $MID = [string]$Msg.MessageID

        # Recupero stringa base dal CSV
        $BaseString = if ($MessageLookup.ContainsKey($MID)) { $MessageLookup[$MID] } else { "Action ID $MID" }

        # Recupero i valori reali (InsStrings)
        $InsStrings = Get-CimInstance -Namespace $Namespace -Query "SELECT InsStrValue FROM SMS_StatMsgInsStrings WHERE RecordID = $RID" | 
                      Select-Object -ExpandProperty InsStrValue

        # --- LOGICA DI SOSTITUZIONE PLACEHOLDER ---
        # Sostituiamo %1 con il primo valore di InsStrings, %2 con il secondo, etc.
        $FormattedName = $BaseString
        for ($i = 0; $i -lt $InsStrings.Count; $i++) {
            $Placeholder = "%$($i + 1)"
            $Value = $InsStrings[$i]
            if ($null -ne $Value) {
                $FormattedName = $FormattedName.Replace($Placeholder, $Value)
            }
        }

        # Pulizia finale: rimuoviamo eventuali placeholder rimasti vuoti o caratteri residui
        $FormattedName = $FormattedName -replace "%\d", "" -replace '"', ""

        # Recupero Utente
        $UserAttr = Get-CimInstance -Namespace $Namespace -Query "SELECT AttributeValue FROM SMS_StatMsgAttributes WHERE RecordID = $RID AND AttributeID = 400" -ErrorAction SilentlyContinue
        
        $FinalAuditLog.Add([PSCustomObject]@{
            Timestamp    = $Msg.Time
            User         = if ($UserAttr) { $UserAttr.AttributeValue } else { "System" }
            ActionID     = $MID
            ActionName   = $FormattedName.Trim()
            OriginSite   = $Msg.SiteCode
            SourceServer = $Msg.MachineName
        })
    }

    # 5. Export JSON
    if (!(Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }
    $FileName = "SCCM_Audit_$($TargetDate).json"
    $FullDest = Join-Path $OutputPath $FileName
    
    $FinalAuditLog | ConvertTo-Json -Compress | Out-File $FullDest -Encoding UTF8
    Write-Host "Operazione completata! File generato: $FullDest" -ForegroundColor Green
}
catch {
    Write-Error "Errore: $($_.Exception.Message)"
}
finally { Set-Location "C:\" }
