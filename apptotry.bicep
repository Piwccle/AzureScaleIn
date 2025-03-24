var location = resourceGroup().location
param adminUsername string = 'sergio'
@secure()
param sshkey string
param vmSize string = 'Standard_B2s'

//var deploymentUser = az.deployer().objectId

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

resource openviduMediaNodeNSG 'Microsoft.Network/networkSecurityGroups@2021-02-01' = {
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

az login --identity

# Generate a random number between 100 and 200
RANDOM_WAIT_TIME=$(( ( RANDOM % 200 )  + 100 ))

# Wait for the random time
sleep $RANDOM_WAIT_TIME

RESOURCE_GROUP_NAME=${resourceGroupName}
VM_SCALE_SET_NAME=${vmScaleSetName}
BEFORE_INSTANCE_ID=$(curl -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq -r '.compute.resourceId')
INSTANCE_ID=$(echo $BEFORE_INSTANCE_ID | awk -F'/' '{print $NF}')

az vmss update --resource-group $RESOURCE_GROUP_NAME --name $VM_SCALE_SET_NAME --instance-id $INSTANCE_ID --protect-from-scale-in false
'''

var scriptParams = {
  subscriptionId: subscription().subscriptionId
  resourceGroupName: resourceGroup().name
  vmScaleSetName: 'myScaleSet'
}

var script = reduce(
  items(scriptParams),
  { value: scriptTemplate },
  (curr, next) => { value: replace(curr.value, '\${${next.key}}', next.value) }
).value


var base64script = base64(script)

var jsonForProtectionScaleIn = '''
  {
    "properties": {
      "protectionPolicy": {
        "protectFromScaleIn": true
      }
    }        
  }
'''
var base64jsonForProtectionScaleIn = base64(jsonForProtectionScaleIn)

var userDataParams = {
  base64script: base64script
  base64jsonForProtectionScaleIn: base64jsonForProtectionScaleIn
  subscriptionId: subscription().subscriptionId
  resourceGroupName: resourceGroup().name
  vmScaleSetName: 'myScaleSet'
}

var userdataTemplate = '''
#!/bin/bash -x
set -u -o pipefail

# Introduce the scripts in the instance
# app.js
echo ${base64script} | base64 -d > /usr/local/bin/stop_media_node.sh
chmod +x /usr/local/bin/stop_media_node.sh

echo ${base64jsonForProtectionScaleIn} | base64 -d > /usr/local/bin/jsonForProtectionScaleIn.json

apt-get update && apt-get install -y 
apt-get install -y unzip && apt-get install -y stress && apt-get install -y jq

# Install azure cli
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

az login --identity 

RESOURCE_GROUP_NAME=${resourceGroupName}
VM_SCALE_SET_NAME=${vmScaleSetName}
BEFORE_INSTANCE_ID=$(curl -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq -r '.compute.resourceId')
INSTANCE_ID=$(echo $BEFORE_INSTANCE_ID | awk -F'/' '{print $NF}')

az vmss update --resource-group $RESOURCE_GROUP_NAME --name $VM_SCALE_SET_NAME --instance-id $INSTANCE_ID --protect-from-scale-in true

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
  name: 'roleAssignmentForScaleSet' // guid
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b24988ac-6180-42a0-ab88-20f7382dd24c'
    )
    principalId: openviduScaleSetMediaNode.identity.principalId
  }
}

resource openviduScaleSetMediaNode 'Microsoft.Compute/virtualMachineScaleSets@2024-07-01' = {
  name: 'myScaleSet'
  location: location
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
                id: openviduMediaNodeNSG.id
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
              threshold: 50
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
              threshold: 50
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

//Crear rol para el Automation Account
resource roleAssignmentAutomationAccount 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: 'roleAssignmentForAutomationAccount' //guid
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b24988ac-6180-42a0-ab88-20f7382dd24c'
    )
    principalId: automationAccount.identity.principalId
  }
}

//Crear un Automation account
resource automationAccount 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: 'myAutomationAccount'
  location: 'global'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
  }
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
        serviceUri: 'https://bd0918eb-a0fe-48c6-b995-432f2f824ca3.webhook.ne.azure-automation.net/webhooks?token=qsl2S7COZrCX%2btafA%2bVIDtDK0WgLXC7gVHP%2fhHbFf6Y%3d'
        useCommonAlertSchema: false
        automationAccountId: automationAccount.id
        runbookName: 'testrunbook'
        webhookResourceId: '${automationAccount.id}/webhooks/Alert1742494428933'
        isGlobalRunbook: false
      }
    ]
  }
}

// Crear el testrunbook


// Crear regla de alerta en Azure Monitor
// Es probable que funcione 
resource scaleInActivityLogRule 'Microsoft.Insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'ScaleInAlertRule'
  location: location
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
