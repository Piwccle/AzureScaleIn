var location = resourceGroup().location
param automationAccountName string

var expiryTime = '2035-03-30T00:00:00Z'
var expiry = '20350330000000'

resource roleAutomationContributorAssignmentAutomationAccount 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('roleAutomationContributorAssignmentAutomationAccount')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'f353d9bd-d4a6-484e-a77a-8050b599b867'
    )
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Crear el automation account y el runbook
resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
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
  location: location
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

resource runbookWebhook 'Microsoft.Automation/automationAccounts/webhooks@2018-06-30' = {
  name: 'Alert${expiry}'
  parent: automationAccount
  properties: {
    expiryTime: expiryTime
    isEnabled: true
    runbook: {
      name: 'testscalein'
    }
  }
  dependsOn: [
    runbookScaleIn
  ]
}

output webhookUri string = runbookWebhook.properties.uri
output webhookId string = runbookWebhook.id
output automationAccountId string = automationAccount.id
output automationAccountPrincipalId string = automationAccount.identity.principalId
