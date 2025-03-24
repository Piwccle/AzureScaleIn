<#
    .DESCRIPTION
        A runbook that will scale in the Media Nodes gracefully in OpenVidu

    .NOTES
        AUTHOR: Sergio Fernández Gómez
        LAST EDIT: March 24, 2025
#>
param
(
    [Parameter (Mandatory=$false)]
        [object] $WebhookData
)
$ErrorActionPreference = "stop"

if (!($WebhookData)) {
    Write-Error "This runbook is meant to be started from an Azure alert webhook only."
    exit
}

# Get the data object from WebhookData
$WebhookBody = (ConvertFrom-Json -InputObject $WebhookData.RequestBody)
# Get the info needed to identify the VM (depends on the payload schema)
$schemaId = $WebhookBody.schemaId

# Check if the schemaId is the one we can manage
if (!($schemaId -eq "Microsoft.Insights/activityLogs")) {
    Write-Error "The alert data schema - $schemaId - is not supported."
    exit
}


# This is the Activity Log Alert schema
$AlertContext = [object] (($WebhookBody.data).context).activityLog
$SubId = $AlertContext.subscriptionId
$ResourceGroupName = $AlertContext.resourceGroupName
$ResourceType = $AlertContext.resourceType
$ResourceName = (($AlertContext.resourceId).Split("/"))[-1]
$status = ($WebhookBody.data).status

# Check if the status is not activated to leave the runbook
if (!($status -eq "Activated")) {
    Write-Error "No action taken. Alert status: $status"
    exit
}
# Determine code path depending on the resourceType
if (!($ResourceType -eq "Microsoft.Compute/virtualMachineScaleSets")) {
    Write-Error "$ResourceType is not a supported resource type for this runbook."
    exit
}

# Print for debug
"resourceType: $ResourceType"
"resourceName: $ResourceName" 
"resourceGroupName: $ResourceGroupName" 
"subscriptionId: $SubId" 

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

#Login into azure
try {
    # Connect to Azure with system-assigned managed identity
    $AzureContext = (Connect-AzAccount -Identity).context
    # set and store context
    $AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
}
catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
}

# Loop the instances in the VMSS to check the tags, and see if one of them is TERMINATING to leave the runbook
$InstancesInVMSS = Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $ResourceName
foreach ($Instance in $InstancesInVMSS) {
    # Check if there is a tag that has "TERMINATING" value
    if ($Instance.Tags.Values -contains "TERMINATING") {
        "Found 'TERMINATING' tag so this runbook will not execute."
        exit
    }
}

# If no VM has been selected previously, select the VM with instance_id 0 and tag it as TERMINATING instance
"Updating TAG in instance with id 0"
$Instance_id = 0
$Instance0 = Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $ResourceName -InstanceId $Instance_id
$Instance0.Tags["STATUS"] = "TERMINATING"
Update-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $ResourceName -InstanceId $Instance_id -Tag $Instance0.Tags

# Run command to let the VM begin terminating, when is done itself will deprotect and the VMSS will delete it, eliminating the tag previously associated and starting a new delete if needed.
Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $InstanceName -CommandId 'RunShellScript' -ScriptPath './usr/local/bin/stop_media_node.sh'