# Check if  the relevant modules are installed and if not install them
$modules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Identity.DirectoryManagement",
    "Microsoft.Graph.Identity.SignIns"
    "WindowsAutoPilotIntune"
    "LAPS"
)

foreach ($module in $modules) {
    if (-not (Get-Module -Name $module -ListAvailable)) {
        Install-Module -Name $module -Force -AllowClobber
    }

    Import-Module $module -Force
}

# Connect to MgGraph 
Connect-MgGraph `
    -Scopes "Device.ReadWrite.All", "BitLockerKey.Read.All", "DeviceManagementServiceConfig.ReadWrite.All" `
    -UseDeviceAuthentication

# Variable to set number of days for device inactivety
$dt = (Get-Date).AddDays(-365)

Get-MgDevice -All | Where-Object {
	$_.ApproximateLastSignInDateTime -and 
    $_.ApproximateLastSignInDateTime -le $dt
} | select-object -Property Id, DeviceId, TrustType, AccountEnabled, OperatingSystem, DisplayName, ApproximateLastSignInDateTime | 
	export-csv DevicesNoActivity_365.csv -NoTypeInformation

# Prompt for user input to continue script
$Confirmation = Read-Host "Are you sure you want to disable/delete exported devices? (Y/N)"
if ($Confirmation -ne 'Y' -and $Confirmation -ne 'Yes') {
	Write-Host "Operation cancelled."
	Exit
}

# Import stale devices CSV
$Devices = Import-Csv "DevicesNoActivity_365.csv"

# Checks to see if device is in AutoPilot and adds "HasAutoPilot" as a header
$AutoPilotDevices = Get-AutopilotDevice

foreach ($Device in $Devices) {
    $AutoPilotMatch = $AutoPilotDevices |
        Where-Object { $_.azureActiveDirectoryDeviceId -eq $Device.Id } |
        Select-Object -First 1
 
    $Device | Add-Member -MemberType NoteProperty -Name "HasAutoPilot" -Value ($null -ne $AutoPilotMatch)
}

#Adds "AutoPilotId" as a header
foreach ($Device in $Devices) {
    $AutoPilotId = $AutoPilotDevices |
        Where-Object { $_.azureActiveDirectoryDeviceId -eq $Device.Id } |
        Select-Object -First 1 -ExpandProperty Id
 
    $Device | Add-Member -MemberType NoteProperty -Name "AutoPilotId" -Value $AutoPilotId
}


# Prepare BitLocker recovery key output

$deviceRecoveryKeys = @()

# Export BitLocker recovery keys

foreach ($Device in $Devices) {

    $recoveryKeys = Get-MgInformationProtectionBitlockerRecoveryKey `
        -Filter "deviceId eq '$($Device.DeviceId)'"

    if ($recoveryKeys) {

        foreach ($key in $recoveryKeys) {

            $deviceRecoveryKeys += [PSCustomObject]@{
                DeviceName    = $Device.DisplayName
                DeviceId      = $Device.DeviceId
                RecoveryKeyId = $key.Id
                RecoveryKey   = (
                    Get-MgInformationProtectionBitlockerRecoveryKey `
                        -BitlockerRecoveryKeyId $key.Id `
                        -Property key
                ).Key
            }
        }

    }
    else {

        $deviceRecoveryKeys += [PSCustomObject]@{
            DeviceName    = $Device.DisplayName
            DeviceId      = $Device.DeviceId
            RecoveryKeyId = "NoKeyFound"
            RecoveryKey   = "NoKeyFound"
        }
    }
}

# Export the device recovery keys to a CSV file
$outputFilePath = Join-Path $PSScriptRoot "DeviceRecoveryKeys.csv"

$deviceRecoveryKeys |
    Export-Csv -Path $outputFilePath -NoTypeInformation -Encoding utf8
	
# Prepare LAPS credential output
$LapsCredentials = @()

# Retrieve LAPS credential output

foreach ($Device in $Devices) {

    $Laps = Get-LapsAADPassword `
        -DeviceIds $Device.Id `
        -IncludePasswords `
        -AsPlainText `
        -ErrorAction Stop

    if ($Laps) {

         foreach ($Credential in $Laps) {

            $LapsCredentials += [PSCustomObject]@{
                DeviceName     = $Device.DisplayName
                DeviceId       = $Device.DeviceId
                LocalAdminUser = $Credential.AccountName
                Password       = $Credential.Password
            }
        }

    }
    else {

        $LapsCredentials += [PSCustomObject]@{
            DeviceName     = $Device.DisplayName
            DeviceId       = $Device.DeviceId
            LocalAdminUser = "NoAccountFound"
            Password       = "NoPasswordFound"
        }
    }
}

# Export the device LAPS credentials to a CSV file
$outputFilePath = Join-Path $PSScriptRoot "Credentials.csv"

$LapsCredentials |
    Export-Csv -Path $outputFilePath -NoTypeInformation -Encoding utf8

# Disable stale devices
$Disable = @{
    accountEnabled = $false
}

# Disables/Deletes stale devices based on TrustType
foreach ($Device in $Devices) {
	
	if ($Device.TrustType -eq "AzureAD" -and $Device.HasAutoPilot -eq $true ) {

        Write-Host "Deleting $($Device.DisplayName) [$($Device.Id)] from AutoPilot"
        
        Remove-AutopilotDevice -Id $Device.AutoPilotId

        Write-Host "Disabling $($Device.DisplayName) [$($Device.Id)]" 

		Update-MgDevice `
			-DeviceId $Device.Id `
			-BodyParameter $Disable `
		
		Write-Host "Deleting $($Device.DisplayName) [$($Device.Id)]"

        Remove-MgDevice -DeviceId $Device.Id
	}
    elseIf ($Device.TrustType -eq "AzureAD" -and $Device.HasAutoPilot -eq $false){
        Write-Host "Disabling $($Device.DisplayName) [$($Device.Id)]" 

		Update-MgDevice `
			-DeviceId $Device.Id `
			-BodyParameter $Disable `
		
		Write-Host "Deleting $($Device.DisplayName) [$($Device.Id)]"

        Remove-MgDevice -DeviceId $Device.Id
    }
	elseif ($Device.TrustType -eq "ServerAD" -or $Device.TrustType -eq "Workplace") {
		
		Write-Host "Deleting $($Device.DisplayName) [$($Device.Id)]"
		
		Remove-MgDevice -DeviceId $Device.Id
	}		
}
