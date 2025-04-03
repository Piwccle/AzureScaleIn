var WebhookExpiryTime = '2035-03-30T00:00:00Z'
var expiry = '20350330000000'

resource automationAccount 'Microsoft.Automation/automationAccounts@2020-01-13-preview' = {
  name: 'myautomationaccount2'
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
  }
}

resource runbookScaleIn 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'testscalein'
  location: resourceGroup().location
  properties: {
    publishContentLink: {
      uri: 'https://raw.githubusercontent.com/Piwccle/scaleInRunBook/refs/heads/main/scaleInRunbook.ps1'
      version: '1.0.0.0'
    }
    runbookType: 'PowerShell72'
    logVerbose: true
    logProgress: true
    logActivityTrace: 0
  }
}

resource webhook 'Microsoft.Automation/automationAccounts/webhooks@2018-06-30' = {
  parent: automationAccount
  name: 'Alert${expiry}'
  properties: {
    isEnabled: true
    expiryTime: WebhookExpiryTime
    runbook: {
      name: 'testscalein'
    }
  }
  dependsOn: [
    runbookScaleIn
  ]
}

output webhookUri string = webhook.properties.uri
output webhookId string = webhook.id
output automationAccountId string = automationAccount.id
