param location string = resourceGroup().location
param adminUsername string = 'azureuser'
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

var nodescript = '''
const express = require('express');
const os = require('os');
const app = express();
const port = 3000;

app.get('/', (req, res) => {
    const localIP = getLocalIP();
    res.send(`
        <html>
            <body>
                <h1>Node.js App</h1>
                <p>IP Address: ${localIP}</p>
                <button onclick="fetch('/shutdown', { method: 'POST' })">Shutdown</button>
            </body>
        </html>
    `);
});

app.post('/shutdown', (req, res) => {
    res.send('Shutting down...');
    process.exit();
});

function getLocalIP() {
    const interfaces = os.networkInterfaces();
    for (const name of Object.keys(interfaces)) {
        for (const iface of interfaces[name]) {
            if (iface.family === 'IPv4' && !iface.internal) {
                return iface.address;
            }
        }
    }
    return '127.0.0.1';
}

app.listen(port, () => {
    const localIP = getLocalIP();
    console.log(`App listening at http://${localIP}:${port}`);
}); 
'''

var base64nodescript = base64(nodescript)

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
  base64nodescript: base64nodescript
  base64jsonForProtectionScaleIn: base64jsonForProtectionScaleIn
}


var userdataTemplate = '''
#!/bin/bash -x
set -eu -o pipefail

# Introduce the scripts in the instance
# app.js
echo ${base64nodescript} | base64 -d > /usr/local/bin/app.js
chmod +x /usr/local/bin/app.js

echo ${base64jsonForProtectionScaleIn} | base64 -d > /usr/local/bin/jsonForProtectionScaleIn.json

apt-get update && apt-get install -y 

# Install Node.js
curl -o- https://fnm.vercel.app/install | bash
fnm install 22

# Install azure cli
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

az login --identity --allow-no-subscriptions

# Make a PUT request to the Azure REST API to update the VM instance with protection policy
curl -X PUT -H "Content-Type: application/json" -H "Authorization: Bearer $(az account get-access-token --query accessToken -o tsv)" \
"${environment().resourceManager}/subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/Microsoft.Compute/virtualMachineScaleSets/{vmScaleSetName}/virtualMachines/{instance-id}?api-version=2019-03-01" \
-d @/usr/local/bin/jsonForProtectionScaleIn.json

export HOME="/root"

#start nodeapp
node /usr/local/bin/app.js
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

resource openviduScaleSetMediaNode 'Microsoft.Compute/virtualMachineScaleSets@2024-07-01' = {
  name: 'myScaleSet'
  location: location
  identity: { type: 'SystemAssigned' }
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
          default: string(1) // Valor por defecto
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


resource functionApp 'Microsoft.Web/sites@2021-02-01' = {
  name: 'myFunctionApp'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: 'myAppServicePlan'
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=yourstorageaccount;AccountKey=yourstorageaccountkey;EndpointSuffix=core.windows.net'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~14'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
      ]
    }
  }
}

resource eventGridSubscription 'Microsoft.EventGrid/eventSubscriptions@2021-06-01-preview' = {
  name: 'myEventGridSubscription'
  scope: tenant()
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: functionApp.id
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Compute/virtualMachineScaleSets/vm/scaleIn/action'
      ]
    }
  }
}
