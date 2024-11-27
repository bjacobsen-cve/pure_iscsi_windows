# VARIABLES
$TargetIQN = "iqn.2010-06.com.purestorage:flasharray.blahblahblah"  # Replace with your iSCSI target IQN
$targetPortals = @("172.16.16.201", "172.16.16.202", "172.16.16.205", "172.16.16.206")  # Replace with your target portals...typically 1 or 2 IPs from each controller for redundancy and high availability.
$targetIPs = @("172.16.16.201", "172.16.16.202", "172.16.16.203", "172.16.16.204", "172.16.16.205", "172.16.16.206", "172.16.16.207", "172.16.16.208")  # Replace with your target IPs. This may be the same as the targetPortals list or may include additional IPs, depending on how many iSCSI interfaces the controller has and how many paths are required to the storage.
$ipPattern = "172.16.16.*"  # Replace with your host initiator IP pattern

# FUNCTIONS
# Function to check if an IP address matches a pattern
function Match-IPPattern {
    param (
        [string]$ip,
        [string]$pattern
    )
    
    # Convert the pattern to a regex
    $regexPattern = [regex]::Escape($pattern).Replace("\*", "\d{1,3}")
    
    return [regex]::IsMatch($ip, "^$regexPattern$")
}

# Function to connect to iSCSI target portals
function Connect-iSCSITargetPortal {
    param (
        [string]$PortalAddress
    )
    Write-Host "Connecting to iSCSI target portal $PortalAddress" -ForegroundColor Yellow
    New-IscsiTargetPortal -TargetPortalAddress $PortalAddress -InitiatorPortalAddress 0.0.0.0 -InitiatorInstanceName ROOT\ISCSIPRT\0000_0
}

# Function to connect to iSCSI target
function Connect-iSCSITarget {
    param (
        [string]$TargetIQN,
        [string]$InitIP,
        [string]$TargIP
    )
    Write-Host "Connecting to iSCSI target $TargetIQN on IP $TargIP from source $InitIP"
    $session = Connect-IscsiTarget -InitiatorPortalAddress $InitIP -TargetPortalAddress $TargIP -NodeAddress $TargetIQN -IsPersistent $true -IsMultipathEnabled $true
    if ($session -eq $null) {
        Write-Host "Failed to connect to iSCSI target $TargetIQN on IP $TargIP from source $InitIP" -ForegroundColor Red
    } else {
        Write-Host "Successfully connected to iSCSI target $TargetIQN on IP $TargIP from source $InitIP" -ForegroundColor Green
    }
}

# Get all network adapters with their IP addresses
$networkAdapters = Get-NetIPAddress | Where-Object { $_.AddressFamily -eq 'IPv4' }

# Filter network adapters based on IP pattern
$initiatorIPs = @()
foreach ($adapter in $networkAdapters) {
    if (Match-IPPattern -ip $adapter.IPAddress -pattern $ipPattern) {
        $initiatorIPs += $adapter.IPAddress
    }
}

# Output results
if ($initiatorIPs.Count -eq 0) {
    Write-Host "No network adapters found with IP addresses matching pattern $ipPattern" -ForegroundColor Red
} else {
    Write-Host "IP addresses matching pattern ${ipPattern}:" -ForegroundColor Yellow
    $initiatorIPs | ForEach-Object { Write-Host $_ }
}

# Set iSCSI service to start automatically
Set-Service -Name MSiSCSI -StartupType Automatic

# Get host IQN
$ServerIQN = (Get-InitiatorPort | Where-Object { $_.NodeAddress -like '*iqn*' }).NodeAddress
Write-Host "Your host IQN is ${ServerIQN}" -ForegroundColor Yellow

# Add Pure Storage as a type of device supported by the Microsoft Device Specific Module (DSM) which is how MPIO policies are applied like Round Robin and Least Queue Depth.
New-MSDSMSupportedHw -VendorId PURE -ProductId FlashArray
Remove-MSDSMSupportedHw -VendorId 'Vendor*' -ProductId 'Product*'
Get-MSDSMSupportedHw

# Set the MPIO Policy
Get-MSDSMGlobalDefaultLoadBalancePolicy
Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR

# Set global MPIO timers
Set-MPIOSetting -NewPathRecoveryInterval 20 -CustomPathRecovery Enabled -NewPDORemovePeriod 30 -NewDiskTimeout 60 -NewPathVerificationState Enabled

#############################################################################################

# Main script
foreach ($portal in $targetPortals) {
    Connect-iSCSITargetPortal -PortalAddress $portal
}

# Pause for portal creation completion
Start-sleep -seconds 10

foreach ($initiatorIP in $initiatorIPs) {
    foreach ($trgIP in $targetIPs) {
        Connect-iSCSITarget -InitIP $initiatorIP -TargIP $trgIP -TargetIQN $TargetIQN
    }
}
		
# Enable MPIO for iSCSI
Write-Host "Enabling MPIO for iSCSI..."
Enable-MSDSMAutomaticClaim -BusType iSCSI
