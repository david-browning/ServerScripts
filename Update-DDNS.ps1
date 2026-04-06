$ErrorActionPreference = 'Stop'

function Get-BaseURI([string]$Domain, [string]$Record) {
    return "https://api.godaddy.com/v1/domains/$Domain/records/A/$Record"
}

function Get-AuthHeaders([string]$APIKey, [string]$APISecret) {
    return @{
        Authorization  = "sso-key $APIKey`:$APISecret"
        'Content-Type' = 'application/json'
    }
}

function Get-PublicIP {
    return (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
}

function Get-GoDaddyRecords([string]$Domain, [string]$Record, [string]$APIKey, [string]$APISecret) {
    $uri = Get-BaseURI -Domain $Domain -Record $Record
    $headers = Get-AuthHeaders -APIKey $APIKey -APISecret $APISecret

    return Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
}

function Set-GoDaddyRecords(
    [string]$Domain,
    [string]$Record,
    [string]$APIKey,
    [string]$APISecret,
    [string]$IPAddress,
    [int]$TTL
) {
    $uri = Get-BaseURI -Domain $Domain -Record $Record
    $headers = Get-AuthHeaders -APIKey $APIKey -APISecret $APISecret

    $body = ConvertTo-Json -InputObject @(
        @{
            data = $IPAddress
            ttl  = $TTL
        }
    ) -Compress

    return Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType 'application/json' -Body $body
}

try {
    $dataPath = Join-Path -Path $PSScriptRoot -ChildPath 'ddns.psd1'
    $config = Import-PowerShellDataFile $dataPath

    $currentIP = Get-PublicIP
    if ([string]::IsNullOrWhiteSpace($currentIP)) {
        Write-Error -ErrorAction Stop "$(Get-Date -Format o) - Could not get the public IP. Terminating..."
    }

    $vpnResult = Get-GoDaddyRecords -Domain $config.Domain -Record $config.Record -APIKey $config.ApiKey -APISecret $config.ApiSecret
    if ($null -eq $vpnResult) {
        Write-Error -ErrorAction Stop "$(Get-Date -Format o) - Could not get GoDaddy data. REST result was NULL. Terminating..."
    }

    if ($vpnResult -isnot [array]) {
        $vpnResult = @($vpnResult)
    }

    if ($vpnResult.Count -ne 1) {
        Write-Error -ErrorAction Stop "$(Get-Date -Format o) - Expected exactly 1 A record for $($config.Record).$($config.Domain), but got $($vpnResult.Count). Terminating..."
    }

    $vpnIP = $vpnResult[0].data.Trim()
    if ([string]::IsNullOrWhiteSpace($vpnIP)) {
        Write-Error -ErrorAction Stop "$(Get-Date -Format o) - Could not get the GoDaddy IP. The data field was empty or null. Terminating..."
    }

    Write-Output "$(Get-Date -Format o) - The current IP is $currentIP. The A record is $vpnIP"

    if ($vpnIP -eq $currentIP) {
        Write-Output "$(Get-Date -Format o) - The IP has not changed. Terminating..."
        exit 0
    }

    Write-Output "$(Get-Date -Format o) - Updating $($config.Record).$($config.Domain) A record from $vpnIP to $currentIP"
    Set-GoDaddyRecords -Domain $config.Domain -Record $config.Record -APIKey $config.ApiKey -APISecret $config.ApiSecret -IPAddress $currentIP -TTL $config.Ttl | Out-Null
    Write-Output "$(Get-Date -Format o) - Successfully updated the A record to $currentIP"
}
catch {
    Write-Error "$(Get-Date -Format o) - Script failed: $_"
    exit 1
}
