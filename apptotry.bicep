var location = resourceGroup().location
param adminUsername string = 'sergio'
@secure()
param sshkey string
param vmSize string = 'Standard_B2s'

resource vmVnet 'Microsoft.Network/virtualNetworks@2021-02-01' = {
  name: 'myVnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'mySubnet'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
    ]
  }
}

resource vmNic 'Microsoft.Network/networkInterfaces@2021-02-01' = {
  name: 'myNic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vmVnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vmNSG 'Microsoft.Network/networkSecurityGroups@2021-02-01' = {
  name: 'myNSG'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHTTP'
        properties: {
          priority: 1001
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHTTPS'
        properties: {
          priority: 1002
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

var scriptTemplate = '''
#!/bin/bash -x

if ! (set -o noclobber ; echo > /tmp/global.lock) ; then
    exit 1  # the global.lock already exists
fi

az login --identity

# Generate a random number between 100 and 200
RANDOM_WAIT_TIME=$(( ( RANDOM % 100 )  + 100 ))

# Wait for the random time
sleep $RANDOM_WAIT_TIME

RESOURCE_GROUP_NAME=${resourceGroupName}
VM_SCALE_SET_NAME=${vmScaleSetName}
SUBSCRIPTION_ID=${subscriptionId}
BEFORE_INSTANCE_ID=$(curl -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq -r '.compute.resourceId')
INSTANCE_ID=$(echo $BEFORE_INSTANCE_ID | awk -F'/' '{print $NF}')
RESOURCE_ID=/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Compute/virtualMachineScaleSets/$VM_SCALE_SET_NAME
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

az tag update --resource-id $RESOURCE_ID --operation replace --tags "STATUS"="HEALTHY" "InstanceDeleteTime"="$TIMESTAMP" "storageAccount"="${storageAccountName}"

az vmss delete-instances --resource-group $RESOURCE_GROUP_NAME --name $VM_SCALE_SET_NAME --instance-ids $INSTANCE_ID
'''

var scriptParams = {
  subscriptionId: subscription().subscriptionId
  resourceGroupName: resourceGroup().name
  vmScaleSetName: 'myScaleSet'
  storageAccountName: storageAccount.name
}

var script = reduce(
  items(scriptParams),
  { value: scriptTemplate },
  (curr, next) => { value: replace(curr.value, '\${${next.key}}', next.value) }
).value

var base64script = base64(script)

var userDataParams = {
  base64script: base64script
  subscriptionId: subscription().subscriptionId
  resourceGroupName: resourceGroup().name
  vmScaleSetName: 'myScaleSet'
  storageAccountName: storageAccount.name
}

var userdataTemplate = '''
#!/bin/bash -x
set -u -o pipefail

# Introduce the scripts in the instance
echo ${base64script} | base64 -d > /usr/local/bin/stop_media_node.sh
chmod +x /usr/local/bin/stop_media_node.sh

apt-get update && apt-get install -y 
apt-get install -y stress && apt-get install -y jq

# Install azure cli
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

az login --identity 

RESOURCE_GROUP_NAME=${resourceGroupName}
VM_SCALE_SET_NAME=${vmScaleSetName}
BEFORE_INSTANCE_ID=$(curl -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq -r '.compute.resourceId')
INSTANCE_ID=$(echo $BEFORE_INSTANCE_ID | awk -F'/' '{print $NF}')

az vmss update --resource-group $RESOURCE_GROUP_NAME --name $VM_SCALE_SET_NAME --instance-id $INSTANCE_ID --protect-from-scale-in true

set +e
az storage blob upload --account-name ${storageAccountName} --container-name automation-locks --name lock.txt --file /dev/null --auth-mode key
set -e

stress --cpu 2 --timeout 600s
'''

var userData = reduce(
  items(userDataParams),
  { value: userdataTemplate },
  (curr, next) => { value: replace(curr.value, '\${${next.key}}', next.value) }
).value

var base64userdata = base64(userData)

var mediaNodeVMSettings = {
  vmName: 'VM-MediaNode'
  osDiskType: 'StandardSSD_LRS'
  ubuntuOSVersion: {
    publisher: 'Canonical'
    offer: '0001-com-ubuntu-server-jammy'
    sku: '22_04-lts-gen2'
    version: 'latest'
  }
  linuxConfiguration: {
    disablePasswordAuthentication: true
    ssh: {
      publicKeys: [
        {
          path: '/home/${adminUsername}/.ssh/authorized_keys'
          keyData: sshkey
        }
      ]
    }
  }
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('roleAssignmentForScaleSet${openviduScaleSetMediaNode.name}')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b24988ac-6180-42a0-ab88-20f7382dd24c'
    )
    principalId: openviduScaleSetMediaNode.identity.principalId
  }
}

param datetime string = utcNow('u')

resource openviduScaleSetMediaNode 'Microsoft.Compute/virtualMachineScaleSets@2024-07-01' = {
  name: 'myScaleSet'
  location: location
  tags: {
    InstanceDeleteTime: datetime
    storageAccount: storageAccount.name
  }
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: vmSize
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    overprovision: true
    upgradePolicy: {
      mode: 'Automatic'
    }
    singlePlacementGroup: true
    platformFaultDomainCount: 1
    virtualMachineProfile: {
      storageProfile: {
        osDisk: {
          createOption: 'FromImage'
          managedDisk: {
            storageAccountType: mediaNodeVMSettings.osDiskType
          }
          diskSizeGB: 50
        }
        imageReference: mediaNodeVMSettings.ubuntuOSVersion
      }
      osProfile: {
        computerNamePrefix: mediaNodeVMSettings.vmName
        adminUsername: adminUsername
        adminPassword: sshkey
        linuxConfiguration: mediaNodeVMSettings.linuxConfiguration
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'mediaNodeNetInterface'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfigMediaNode'
                  properties: {
                    subnet: {
                      id: vmVnet.properties.subnets[0].id
                    }
                    publicIPAddressConfiguration: {
                      name: 'publicIPAddressMediaNode'
                      properties: {
                        publicIPAddressVersion: 'IPv4'
                      }
                    }
                  }
                }
              ]
              networkSecurityGroup: {
                id: vmNSG.id
              }
            }
          }
        ]
      }
      userData: base64userdata
    }
  }
}

//Create a autoscale setting for the media nodes
resource openviduAutoScaleSettings 'Microsoft.Insights/autoscaleSettings@2022-10-01' = {
  name: 'myAutoscaleSettings'
  location: resourceGroup().location
  properties: {
    profiles: [
      {
        name: 'openvidu-medianode-autoscale'
        capacity: {
          minimum: string(1) // Mínimo de instancias
          maximum: string(10) // Máximo de instancias
          default: string(2) // Valor por defecto
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
              metricResourceUri: openviduScaleSetMediaNode.id
              statistic: 'Average'
              operator: 'GreaterThan'
              threshold: 80
              timeAggregation: 'Average'
              timeWindow: 'PT5M'
              timeGrain: 'PT1M'
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricNamespace: 'Microsoft.Compute/virtualMachineScaleSets'
              metricResourceUri: openviduScaleSetMediaNode.id
              statistic: 'Average'
              operator: 'LessThan'
              threshold: 60
              timeAggregation: 'Average'
              timeWindow: 'PT5M'
              timeGrain: 'PT1M'
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
        ]
      }
    ]
    enabled: true
    targetResourceUri: openviduScaleSetMediaNode.id
  }
}

module webhookModule './webhookdeployment.json' = {
  params: {
    automationAccountName: 'myautomationaccount12342222556'
    runbookName: 'testscalein'
    webhookName: 'webhook'
    WebhookExpiryTime: '2035-03-30T00:00:00Z'
    _artifactsLocation: 'https://raw.githubusercontent.com/Piwccle/AzureScaleIn/refs/heads/main/scaleInRunbook.ps1'
  }
  name: 'WebhookDeployment'
}

resource actionGroupScaleIn 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'actiongrouptest'
  location: 'global'
  properties: {
    groupShortName: 'tacg'
    enabled: true
    automationRunbookReceivers: [
      {
        name: 'scalein'
        useCommonAlertSchema: false
        automationAccountId: webhookModule.outputs.automationAccountId
        runbookName: 'testscalein'
        webhookResourceId: webhookModule.outputs.webhookId
        isGlobalRunbook: false
        serviceUri: webhookModule.outputs.webhookUri
      }
    ]
  }
}

// Crear regla de alerta en Azure Monitor
resource scaleInActivityLogRule 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'ScaleInAlertRule'
  location: 'global'
  properties: {
    scopes: [
      openviduScaleSetMediaNode.id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Compute/virtualMachineScaleSets/write'
        }
        {
          field: 'level'
          containsAny: [
            'error'
          ]
        }
        {
          field: 'status'
          containsAny: [
            'failed'
          ]
        }
        {
          field: 'caller'
          equals: '42628537-ebd8-40bf-941a-dddd338e1fe9'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupScaleIn.id
        }
      ]
    }
    enabled: true
  }
}

// Create a storage account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'lockstorage${uniqueString(resourceGroup().id)}'
  location: resourceGroup().location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Cool'
    supportsHttpsTrafficOnly: true
  }
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${storageAccount.name}/default/automation-locks'
  properties: {
    publicAccess: 'None'
  }
}
