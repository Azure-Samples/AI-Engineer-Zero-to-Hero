// Add Responses API operations to APIM for Deep Research
// The Responses API is needed for o3-deep-research model

param apimName string

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' existing = {
  parent: apim
  name: 'openai'
}

// v1/responses endpoint for Deep Research
resource responsesV1Op 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'responses-v1'
  properties: {
    displayName: 'Responses API v1'
    method: 'POST'
    urlTemplate: '/v1/responses'
  }
}

// GET responses by ID (for polling background tasks)
resource responsesGetOp 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'responses-get'
  properties: {
    displayName: 'Get Response'
    method: 'GET'
    urlTemplate: '/v1/responses/{response-id}'
    templateParameters: [
      { name: 'response-id', required: true, type: 'string' }
    ]
  }
}
