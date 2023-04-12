# Azure Partner center GitHub action

This action update the artifact of a plan within the Azure partner center offer.

It supports both Application offer and Azure Virtual Machine offer.

## Prerequisites

To have the action works, you will need to setup three repository secrets for your pipeline(you can also pass them as parameters but it is not recommended):

* CLIENT_ID: Client ID for an Azure AD application.
* SECRET_VALUE: Secret value of the application.
* TENANT_ID: Tenant ID you'd like to run pipeline against.

Here are the steps to get those credentials:

1. [Complete prerequisites for using the Partner Center submission API](https://learn.microsoft.com/en-us/azure/marketplace/azure-app-apis#how-to-associate-an-azure-ad-application-with-your-partner-center-account).

1. [Quickstart: Register an application with the Microsoft identity platform](https://learn.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app#changing-the-application-registration-to-support-multi-tenant)

1. [Associate an existing Azure AD tenant with your Partner Center account](https://learn.microsoft.com/en-us/windows/apps/publish/partner-center/associate-existing-azure-ad-tenant-with-partner-center-account).

## Inputs

### `clientId`

**Required** Client ID for an Azure AD application.

### `secretValue`

**Required** Secret value of the application.

### `tenantId`

**Required** Tenant ID you'd like to run pipeline against.

### `offerName`

**Required** The name of the offer.

### `planName`

**Required** The name of the plan.

### `offerType`

**Required** The type of the offer, supported values are `application_offer` and `vm_image_offer`.

### `filePath`

**Required for Application Offer** The path to the artifact(ZIP file).

### `artifactVersion`

**Required for Application Offer** The new version of the artifact.

### `imageVersionNumber`

**Required for Azure Virtual Machine Offer** The new version of the image.

### `imageType`

**Required for Azure Virtual Machine Offer** The type of the image, supported value examples are `x64Gen1`, `x64Gen2` etc.

### `osDiskSasUrl`

**Required for Azure Virtual Machine Offer** The OS Disk SAS URL.

### `dataDiskSasUrl`

**Required for Azure Virtual Machine Offer** The Data Disk SAS URL.

### `operatingSystemFamily`

**Required for Azure Virtual Machine Offer** The OS family like `linux`.

### `operatingSystemType`

**Required for Azure Virtual Machine Offer** The OS type like `redHat`.

## Outputs

## Example usage

### For Application Offer
```terminal
uses: microsoft/microsoft-partner-center-github-action@v1
with:
  offerName: offerName
  planName: planName
  filePath: filePath
  artifactVersion: artifactVersion
  clientId: clientId
  secretValue: secretValue
  tenantId: tenantId
  offerType: 'application_offer'
```

### For Virtual Machine Offer
```terminal
uses: microsoft/microsoft-partner-center-github-action@v1
with:
  offerName: offerName
  planName: planName
  clientId: clientId
  secretValue: secretValue
  tenantId: tenantId
  offerType: 'vm_image_offer'
  imageVersionNumber: imageVersionNumber
  imageType: imageType
  osDiskSasUrl: osDiskSasUrl
  dataDiskSasUrl: dataDiskSasUrl
  operatingSystemFamily: operatingSystemFamily
  operatingSystemType: operatingSystemType
```