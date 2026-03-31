targetScope = 'resourceGroup'

param location string = resourceGroup().location
param deployerPrincipalId string

@description('Version for GPT-4.1 model deployments.')
param gpt41ModelVersion string = '2025-04-14'

@description('TPM capacity for primary (eastus2) GPT-4.1 deployment. Set low (1) to trigger 429 for failover demo.')
param primaryCapacity int = 1

@description('TPM capacity for fallback (swedencentral) GPT-4.1 deployment.')
param fallbackCapacity int = 30

// ─────────────────────────────────────────────────────────────
// Naming
// ─────────────────────────────────────────────────────────────
var suffix = substring(uniqueString(subscription().subscriptionId, resourceGroup().id), 0, 6)
var primaryHubName   = 'foundry-hub-${suffix}'
var fallbackHubName  = 'foundry-hub-swedencentral-${suffix}'
var storageName      = 'foundryhub${suffix}'
var apimName         = 'foundry-apim-${suffix}'

// ─────────────────────────────────────────────────────────────
// Storage (required by AI Services)
// ─────────────────────────────────────────────────────────────
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
}

// ─────────────────────────────────────────────────────────────
// PRIMARY HUB (eastus2) – low TPM to trigger 429
// ─────────────────────────────────────────────────────────────
resource primaryHub 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: primaryHubName
  location: 'eastus2'
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: primaryHubName
    publicNetworkAccess: 'Enabled'
  }
}

resource primaryModel 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: primaryHub
  name: 'gpt-4.1'
  sku: { name: 'GlobalStandard', capacity: primaryCapacity }
  properties: {
    model: { name: 'gpt-4.1', format: 'OpenAI', version: gpt41ModelVersion }
  }
}

// ─────────────────────────────────────────────────────────────
// FALLBACK HUB (swedencentral) – higher TPM
// ─────────────────────────────────────────────────────────────
resource fallbackHub 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: fallbackHubName
  location: 'swedencentral'
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: fallbackHubName
    publicNetworkAccess: 'Enabled'
  }
}

resource fallbackModel 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: fallbackHub
  name: 'gpt-4.1'
  sku: { name: 'GlobalStandard', capacity: fallbackCapacity }
  properties: {
    model: { name: 'gpt-4.1', format: 'OpenAI', version: gpt41ModelVersion }
  }
}

// ─────────────────────────────────────────────────────────────
// APIM (StandardV2 – required for backend pools)
// ─────────────────────────────────────────────────────────────
resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: apimName
  location: location
  sku: { name: 'StandardV2', capacity: 1 }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: 'admin@contoso.com'
    publisherName: 'Contoso AI'
  }
}

// ─────────────────────────────────────────────────────────────
// RBAC – APIM managed identity → Cognitive Services User
// ─────────────────────────────────────────────────────────────
var cogUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'a97b65f3-24c7-4388-baec-2e87135dc908'
)

resource apimRolePrimary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(primaryHub.id, apim.id, 'CognitiveServicesUser')
  scope: primaryHub
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cogUserRoleId
  }
}

resource apimRoleFallback 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(fallbackHub.id, apim.id, 'CognitiveServicesUser')
  scope: fallbackHub
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cogUserRoleId
  }
}

// Deployer user access
resource deployerRolePrimary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(primaryHub.id, deployerPrincipalId, 'CognitiveServicesUser')
  scope: primaryHub
  properties: {
    principalId: deployerPrincipalId
    principalType: 'User'
    roleDefinitionId: cogUserRoleId
  }
}

resource deployerRoleFallback 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(fallbackHub.id, deployerPrincipalId, 'CognitiveServicesUser')
  scope: fallbackHub
  properties: {
    principalId: deployerPrincipalId
    principalType: 'User'
    roleDefinitionId: cogUserRoleId
  }
}

// ─────────────────────────────────────────────────────────────
// APIM BACKENDS with Circuit Breakers
//   - Trip on a single 429 within 10 s
//   - Stay open for 10 s (or honour Retry-After header)
// ─────────────────────────────────────────────────────────────
resource backendPrimary 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'openai'
  properties: {
    url: '${primaryHub.properties.endpoint}openai'
    protocol: 'http'
    circuitBreaker: {
      rules: [
        {
          name: 'breakOnThrottling'
          failureCondition: {
            count: 1
            interval: 'PT10S'
            statusCodeRanges: [ { min: 429, max: 429 } ]
          }
          tripDuration: 'PT10S'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

resource backendFallback 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'openai-swedencentral'
  properties: {
    url: '${fallbackHub.properties.endpoint}openai'
    protocol: 'http'
    description: 'Sweden Central hub for GPT-4.1 failover'
    circuitBreaker: {
      rules: [
        {
          name: 'breakOnThrottling'
          failureCondition: {
            count: 1
            interval: 'PT10S'
            statusCodeRanges: [ { min: 429, max: 429 } ]
          }
          tripDuration: 'PT10S'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

// ─────────────────────────────────────────────────────────────
// BACKEND POOL – priority-based failover
//   Priority 1 = eastus2 (primary, low TPM)
//   Priority 2 = swedencentral (fallback, higher TPM)
// ─────────────────────────────────────────────────────────────
resource backendPool 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'openai-failover-pool'
  properties: {
    type: 'Pool'
    pool: {
      services: [
        { id: backendPrimary.id, priority: 1, weight: 1 }
        { id: backendFallback.id, priority: 2, weight: 1 }
      ]
    }
  }
}

// ─────────────────────────────────────────────────────────────
// API + Operations
// ─────────────────────────────────────────────────────────────
resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'openai'
  properties: {
    displayName: 'OpenAI'
    path: 'openai'
    protocols: [ 'https' ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
  }
}

// Chat Completions – uses the failover pool
resource chatOp 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'chat'
  properties: {
    displayName: 'Chat Completions'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/chat/completions'
    templateParameters: [
      { name: 'deployment-id', required: true, type: 'string' }
    ]
  }
}

// ─────────────────────────────────────────────────────────────
// POLICIES
// ─────────────────────────────────────────────────────────────

// API-level: default query param + managed-identity auth + rate limit
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'xml'
    value: '''
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="openai-failover-pool" />
    <set-query-parameter name="api-version" exists-action="skip">
      <value>2024-10-21</value>
    </set-query-parameter>
    <authentication-managed-identity resource="https://cognitiveservices.azure.com"
        output-token-variable-name="msi-access-token" ignore-error="false" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
    <rate-limit calls="200" renewal-period="60" />
  </inbound>
  <backend>
    <retry condition="@(context.Response.StatusCode == 429)"
           count="3" interval="0" first-fast-retry="true">
      <forward-request buffer-request-body="true" />
    </retry>
  </backend>
  <outbound>
    <base />
  </outbound>
</policies>'''
  }
}

// Subscription for API key access
resource apimSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: 'foundry-gateway'
  properties: {
    displayName: 'Foundry Gateway Access'
    scope: '/apis/${api.name}'
    state: 'active'
  }
}

// ─────────────────────────────────────────────────────────────
// Outputs
// ─────────────────────────────────────────────────────────────
output apimUrl string = '${apim.properties.gatewayUrl}/openai'
output apimName string = apim.name
output primaryEndpoint string = primaryHub.properties.endpoint
output fallbackEndpoint string = fallbackHub.properties.endpoint
output primaryCapacityTPM int = primaryCapacity
output fallbackCapacityTPM int = fallbackCapacity
