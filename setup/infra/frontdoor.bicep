param prefix string
param origins string[] = []

var configuredOrigins = [for (hostname, i) in origins: {
  name: 'region-${i}'
  hostName: hostname
  originHostHeader: hostname
  priority: 1
  weight: 1000
  httpsPort: 443
  enabledState: 'Enabled'
  enforceCertificateNameCheck: true
}]

module profile 'br/public:avm/res/cdn/profile:0.14.0' = {
  params: {
    name: '${prefix}-fd'
    location: 'global'
    sku: 'Standard_AzureFrontDoor'
    enableTelemetry: false
    originResponseTimeoutSeconds: 30
    tags: { managedBy: 'EPP-FrontDoor-Setup' }
    originGroups: empty(origins) ? [] : [
      {
        name: 'epp'
        sessionAffinityState: 'Disabled'
        loadBalancingSettings: {
          sampleSize: 4
          successfulSamplesRequired: 3
          additionalLatencyInMilliseconds: 50
        }
        healthProbeSettings: {
          probePath: '/api/health/ready'
          probeProtocol: 'Https'
          probeRequestType: 'HEAD'
          probeIntervalInSeconds: 30
        }
        origins: configuredOrigins
      }
    ]
    afdEndpoints: [
      {
        name: '${prefix}-edge'
        enabledState: 'Enabled'
        routes: empty(origins) ? [] : [
          {
            name: 'send-otp'
            originGroupName: 'epp'
            enabledState: 'Enabled'
            forwardingProtocol: 'HttpsOnly'
            supportedProtocols: ['Https']
            httpsRedirect: 'Enabled'
            linkToDefaultDomain: 'Enabled'
            patternsToMatch: ['/api/SendOtp', '/api/health/ready']
            // Omitting cacheConfiguration keeps nonce responses and readiness uncached.
          }
        ]
      }
    ]
  }
}
