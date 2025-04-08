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
    exit 1
}


# This is the Activity Log Alert schema
$AlertContext = [object] (($WebhookBody.data).context).activityLog
$ResourceGroupName = $AlertContext.resourceGroupName
$ResourceType = $AlertContext.resourceType
$ResourceName = (($AlertContext.resourceId).Split("/"))[-1]
$status = ($WebhookBody.data).status

# Check if the status is not activated to leave the runbook
if (!($status -eq "Activated")) {
    Write-Error "No action taken. Alert status: $status"
    exit 1
}
# Determine code path depending on the resourceType
if (!($ResourceType -eq "Microsoft.Compute/virtualMachineScaleSets")) {
    Write-Error "$ResourceType is not a supported resource type for this runbook."
    exit 1
}

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

#Get the timestamp of the event that triggered the runbook
$EventTimestamp = [datetime]$WebhookBody.data.EventTimestamp

$VMSS = Get-AzVmss -ResourceGroupName $ResourceGroupName -VMScaleSetName $ResourceName
"Checking if it was deleted a instance 5 minutes ago or less"
#$CurrentTime = Get-Date
$TimeStampTag = $VMSS.Tags["InstanceDeleteTime"]
$DateTag = [datetime]$TimeStampTag
#$Diff = $CurrentTime - $DateTag
if ($EventTimestamp -lt $DateTag) {
    Write-Output "Instance was deleted 5 minutes ago or less. Exiting..."
    exit 1
}
"Done checking"

"Checking if theres more than 1 instance in the VMSS"
$InstanceCount = $InstancesInVMSS.Count
if ($InstanceCount -le 1) {
    "There is only one instance in the VMSS. Exiting..."
    exit 1  # Exit the script if there is only one instance
}

# Check the tags in the VMSS to see if there is a tag with value TERMINATING
"Checking TAG for TERMINATING"
if($VMSS.Tags.Values -contains "TERMINATING"){
    "Found 'TERMINATING' tag so this runbook will not execute."
    exit 1
}
"Terminating not found changing TAG"
$VMSS.Tags["STATUS"] = "TERMINATING"
$job = Start-Job {
    Set-AzResource -ResourceId $using:VMSS.Id -Tag $using:VMSS.Tags -Force
}

$completed = Wait-Job -Job $job -Timeout 20

if (-not $completed) {
    Write-Output "The tag update operation timed out"
    Stop-Job -Job $job
    Remove-Job -Job $job
    exit 1
} else {
    Receive-Job -Job $job
}
"TAG updated"

# If no VM has been selected previously, select the VM with instance_id 0 and tag it as TERMINATING instance
$InstanceId = $InstancesInVMSS[0].InstanceId

"Checking if one Run Command is executing"
# Get the instances and select the index 0 instance to check if runcommand is running on it and later invoke the run command
$InstancesInVMSS = Get-AzVmssVM -ResourceGroupName $ResourceGroupName -VMScaleSetName $ResourceName

# Iterate through each instance and check if RunCommand is still running
foreach ($Instance in $InstancesInVMSS) {
    $runCommandStatus = Get-AzVmssVMRunCommand -ResourceGroupName $ResourceGroupName -VMScaleSetName $ResourceName -InstanceId $Instance.InstanceId

    # Check if the RunCommand is still running
    if ($runCommandStatus.ProvisioningState -eq "Running") {
        Write-Output "Instance $($Instance.InstanceId) is still running a command. Exiting..."
        exit 1  # Exit the script if any instance is still running the command
    }
}
"Done checking"

"Sending RunCommand"
$job = Start-Job {
    Invoke-AzVmssVMRunCommand -ResourceGroupName $using:ResourceGroupName -VMScaleSetName $using:ResourceName -InstanceId $using:InstanceId -CommandId 'RunShellScript' -ScriptString 'sudo /usr/local/bin/stop_media_node.sh'
}
$completed = Wait-Job -Job $job -Timeout 60
if (-not $completed) {
    Write-Warning "RunCommand Send"
    Stop-Job -Job $job
    Remove-Job -Job $job
} else {
    $result = Receive-Job -Job $job
    Write-Output "RunCommand result:"
    $result.Value[0].Message
}
exit 0