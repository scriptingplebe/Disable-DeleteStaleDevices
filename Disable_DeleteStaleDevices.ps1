# Check if  the relevant modules are installed and if not install them
$modules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Identity.DirectoryManagement",
    "Microsoft.Graph.Identity.SignIns"
)

foreach ($module in $modules) {
    if (-not (Get-Module -Name $module -ListAvailable)) {
        Install-Module -Name $module -Force -AllowClobber
    }

    Import-Module $module -Force
}

# Connect to MgGraph 
Connect-MgGraph ` 
    -Scopes "Device.ReadWrite.All", "BitLockerKey.Read.All" `
    -UseDeviceAuthentication

# Export stale devices that haven't signed in past 240 days
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
	
	if ($Device.TrustType -eq "AzureAD") {

        Write-Host "Disabling $($Device.DisplayName) [$($Device.Id)]" 

		Update-MgDevice `
			-DeviceId $Device.Id `
			-BodyParameter $Disable `
		
		Write-Host "Deleting $($Device.DisplayName) [$($Device.Id)]"

        Remove-MgDevice `
            -DeviceId $Device.Id
	}
	if ($Device.TrustType -eq "ServerAD" -or $Device.TrustType -eq "Workplace") {
		
		Write-Host "Deleting $($Device.DisplayName) [$($Device.Id)]"
		
		Remove-MgDevice `
			-DeviceId $Device.Id
	}		
}