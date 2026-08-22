// ---------------------------------------------------------------------------
// Outbound email: a Logic App fronting the Office 365 connector.
// ---------------------------------------------------------------------------
// WHY THIS RATHER THAN SMTP
//
// A Drupal site needs to send mail — password resets, notifications, cron
// reports. The obvious options and why they lose:
//
//   SMTP credentials    Modern tenants disable basic authentication for SMTP, and
//                       where it still works it means a long-lived password in
//                       the app's configuration with permission to send as a
//                       mailbox. Nothing rotates it.
//   SendGrid / Mailgun  Another vendor, another credential, and mail arrives from
//                       outside the institution's domain — which is exactly what
//                       DMARC is designed to reject.
//   Graph API directly  Correct, but needs an app registration with
//                       Mail.Send application permission, which is tenant-wide
//                       consent to send as ANY mailbox. Hard to get approved, and
//                       rightly so.
//
// A Logic App with the Office 365 connector sends as ONE authorised mailbox,
// consented interactively once by a human who owns that mailbox. The app holds no
// credential at all: it calls the Logic App with a managed-identity token.
//
// THE ONE MANUAL STEP
//
// The API connection below is created unauthorised. Someone has to open it in the
// portal and sign in as the sending account — an OAuth consent that cannot be
// automated, because the whole point is that a human proves they control the
// mailbox. scripts/setup-email.sh prints the exact steps. Until it is done, the
// Logic App exists and returns an error when called.
// ---------------------------------------------------------------------------
param location string
param connectionName string
param logicAppName string

@description('Display name for the connection, shown in the portal where someone has to authorise it.')
param connectionDisplayName string = 'Office 365 (authorise me)'

@description('''
Outbound addresses permitted to trigger the workflow, as CIDR strings.

Filled in by the caller from the platform module's own output, so the allow-list
is correct in a single deployment. The source deployments this is modelled on had
to run a separate script afterwards to discover these, which meant the Logic App
spent its first minutes callable from anywhere.

Empty means no IP restriction — the AAD policy below still applies, but you are
relying on one control instead of two.
''')
param allowedCallerIps array = []

@description('''
Object (principal) ID of the identity permitted to trigger the workflow.

This is the improvement worth understanding. The usual recipe validates only two
claims — that the token came from this tenant (`iss`) and was minted for ARM
(`aud`) — which means ANY principal in the tenant holding an ARM token can send
mail through this workflow. That is a large set, and on a shared tenant it
includes principals you have never heard of.

Pinning `sub` as well narrows it to exactly one identity: the app's managed
identity. `iss` is the v1 endpoint (sts.windows.net), so `sub` carries the service
principal's object ID.

Empty falls back to issuer-and-audience only, which is the weaker behaviour and
is why the parameter has no default.
''')
param callerPrincipalId string = ''

// ---------------------------------------------------------------------------
// The API connection. Created unauthorised on purpose — see the header.
// ---------------------------------------------------------------------------
resource o365 'Microsoft.Web/connections@2016-06-01' = {
  name: connectionName
  location: location
  properties: {
    displayName: connectionDisplayName
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
    }
  }
}

// ---------------------------------------------------------------------------
// Claims the trigger requires. Built conditionally so the stronger form is used
// whenever a principal is supplied.
// ---------------------------------------------------------------------------
var baseClaims = [
  {
    name: 'iss'
    value: 'https://sts.windows.net/${subscription().tenantId}/'
  }
  {
    name: 'aud'
    // environment().resourceManager rather than a literal, so this works in
    // sovereign clouds (US Gov, China) where ARM is not management.azure.com.
    // The claim has to match the token's audience exactly, trailing slash and
    // all, which is what this function returns.
    value: environment().resourceManager
  }
]
var subjectClaim = [
  {
    name: 'sub'
    value: callerPrincipalId
  }
]
var triggerClaims = empty(callerPrincipalId) ? baseClaims : concat(baseClaims, subjectClaim)

resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  properties: {
    state: 'Enabled'

    // -------------------------------------------------------------------
    // Two independent controls on who may trigger this, because either one
    // alone is thin:
    //
    //   the AAD policy   proves the caller holds a token from this tenant, for
    //                    ARM, and (when pinned) belongs to this app's identity
    //   the IP list      proves the call came from the app's own egress
    //
    // scripts/setup-email.sh strips the SAS query string from the callback URL
    // before storing it, so the shared-access signature — which would bypass
    // the AAD policy entirely — is never the thing in use.
    // -------------------------------------------------------------------
    accessControl: {
      triggers: {
        allowedCallerIpAddresses: allowedCallerIps
        openAuthenticationPolicies: {
          policies: {
            aad_policy: {
              type: 'AAD'
              claims: triggerClaims
            }
          }
        }
      }
    }

    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            // The contract the Drupal mail plugin posts against. `to` is a
            // semicolon-separated list, which is what the O365 connector wants.
            schema: {
              type: 'object'
              properties: {
                to: { type: 'string' }
                subject: { type: 'string' }
                body: { type: 'string' }
                cc: { type: 'string' }
                bcc: { type: 'string' }
                replyTo: { type: 'string' }
                isHtml: { type: 'boolean' }
              }
              required: ['to', 'subject', 'body']
            }
          }
        }
      }
      actions: {
        Send_an_email: {
          type: 'ApiConnection'
          inputs: {
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'office365\'][\'connectionId\']'
              }
            }
            method: 'post'
            path: '/v2/Mail'
            body: {
              To: '@triggerBody()?[\'to\']'
              Subject: '@triggerBody()?[\'subject\']'
              // Drupal's mail system hands over a fully-formed body. When it is
              // plain text it must be wrapped, or the O365 connector — which
              // always sends HTML — collapses every newline and the mail arrives
              // as one paragraph. `isHtml` lets the sender opt out.
              Body: '@{if(equals(triggerBody()?[\'isHtml\'], true), triggerBody()?[\'body\'], concat(\'<pre style="font-family:inherit;white-space:pre-wrap">\', triggerBody()?[\'body\'], \'</pre>\'))}'
              Cc: '@triggerBody()?[\'cc\']'
              Bcc: '@triggerBody()?[\'bcc\']'
              ReplyTo: '@triggerBody()?[\'replyTo\']'
              Importance: 'Normal'
            }
          }
        }
      }
      outputs: {}
    }

    parameters: {
      '$connections': {
        value: {
          office365: {
            connectionId: o365.id
            connectionName: 'office365'
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
          }
        }
      }
    }
  }
}

output logicAppName string = workflow.name
output logicAppId string = workflow.id
output connectionName string = o365.name
output connectionId string = o365.id
// The portal blade a human has to open to authorise the connection. Printed by
// setup-email.sh, because "find it in the portal" is how a one-time manual step
// becomes a twenty-minute hunt.
output authorizeUrl string = 'https://portal.azure.com/#@/resource${o365.id}/edit'
output ipRestrictionCount int = length(allowedCallerIps)
output subjectClaimPinned bool = !empty(callerPrincipalId)
