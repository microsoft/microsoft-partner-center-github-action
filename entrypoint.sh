#!/bin/sh

export token=$1
export offerName=$2
export planName=$3
export filePath=$4
export artifactVersion=$5
export fileName=$(basename ${filePath})

# Get product by name
products=$(curl -X GET \
  https://api.partner.microsoft.com/v1.0/ingestion/products \
  -H "Authorization: Bearer ${token}" \
  -H "accept: application/json" | jq .)

if [ $? -ne 0 ]; then
    echo "Error happens when getting offer list." >&2
    exit 1
fi

echo "first page of offers:" >&2
echo $products | jq . >&2

nextProductsLink=$(echo ${products} | jq -r '.nextLink')
productId=$(echo ${products} | jq -r --arg offerName $offerName '.value | .[] | select(.name==$offerName) | .id')

echo "offer finding result in first page: " $nextProductsLink $productId >&2

# if cannot find name and has nextLink, try next 
attempt=0
while [ -z ${productId} ] && [ ! -z "${nextProductsLink}" ] && [ $attempt -le 10 ]; do
    echo https://api.partner.microsoft.com/${nextProductsLink}

    products=$(curl -X GET \
    https://api.partner.microsoft.com/"${nextProductsLink}" \
    -H "Authorization: Bearer ${token}" \
    -H "accept: application/json" | jq .)

    if [ $? -ne 0 ]; then
        echo "Error happens when getting offer list." >&2
        exit 1
    fi

    echo "next page of offers:" >&2
    echo $products | jq . >&2
    
    nextProductsLink=$(echo ${products} | jq -r '.nextLink')
    productId=$(echo ${products} | jq -r --arg offerName $offerName '.value | .[] | select(.name==$offerName) | .id')

    echo "offer finding result in next page: " $nextProductsLink $productId >&2

	attempt=$((attempt+1))
	sleep 10s
done

# if cannot find productId by product name, exit 1
if [ -z ${productId} ]; then
    echo "Error: cannot get offer by name" >&2
    exit 1
fi

# Get variantId by plan name
variantId=""
variants=$(curl -X GET \
  https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/variants \
  -H "Authorization: Bearer ${token}" \
  -H "accept: application/json" | jq .)

if [ $? -ne 0 ]; then
    echo "Error happens when getting plan list." >&2
    exit 1
fi

echo "all plans under the offer:" >&2
echo $variants | jq . >&2

variantId=$(echo ${variants} | jq -r --arg planName $planName '.value | .[] | select(.friendlyName==$planName) | .id')

# if cannot find variantId by list name, exit 1
if [ -z ${variantId} ]; then
    echo "Error: cannot get plan id by name" >&2
    exit 1
fi

echo "variantId is: " $variantId

# Get draft instance id by variantId
echo "Get draft instance id by variantId"
draftInstanceId=""
instances=$(curl -X GET \
  "https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/branches/getByModule(module=Package)" \
  -H "Authorization: Bearer ${token}" \
  -H "accept: application/json" | jq .)

if [ $? -ne 0 ]; then
    echo "Error happens when getting draft instances." >&2
    exit 1
fi

echo "all draft plan instances under the offer:" >&2
echo $instances >&2

draftInstanceId=$(echo ${instances} | jq -r --arg variantId $variantId '.value | .[] | select(.variantID==$variantId) | .currentDraftInstanceID')

# if cannot find draftInstanceId by variantId, exit 1
if [ -z ${draftInstanceId} ]; then
    echo "Error: cannot get draftInstanceId by plan id" >&2
    exit 1
fi

echo "draftInstanceId is: " $draftInstanceId


# Create a new package request body
generateNewPackageRequestBody()
{
    cat <<EOF
{
    "resourceType": "AzureApplicationPackage",
    "fileName": "${fileName}"
}
EOF
}

packageInfo=$(curl -X POST \
  https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packages \
  -H "Authorization: Bearer ${token}" \
  -H "accept: application/json" \
  -H "Content-Type: application/json" \
  -d "$(generateNewPackageRequestBody)" | jq .)

if [ $? -ne 0 ]; then
    echo "Error happens when creating new artifact upload task" >&2
    exit 1
fi

echo "new created package info: " >&2
echo $packageInfo >&2

state=$(echo $packageInfo | jq -r '.state')
fileSasUri=$(echo $packageInfo | jq -r '.fileSasUri')
packageId=$(echo $packageInfo | jq -r '.id')
dataEtag=$(echo $packageInfo | jq '.["@odata.etag"]')

# Upload file
echo "upload artifact starts" >&2
dateNow=$(date -Ru | sed 's/\+0000/GMT/')
azcliVersion="2018-03-28"

curl -X PUT -H "Content-Type: application/octet-stream" \
  -H "x-ms-date: ${dateNow}" \
  -H "x-ms-version: ${azcliVersion}" \
  -H "x-ms-blob-type: BlockBlob" \
  --data-binary "@${filePath}" \
  "${fileSasUri}"

if [ $? -ne 0 ]; then
    echo "Error happens when uploading artifact" >&2
    exit 1
fi
echo "upload artifact ends" >&2

# Change new package state request body
generateUploadedPackageRequestBody()
{
    cat <<EOF
{
    "resourceType": "AzureApplicationPackage",
    "fileName": "${fileName}",
    "fileSasUri": "${fileSasUri}",
    "State": "Uploaded",
    "@odata.etag": ${dataEtag},
    "id": "${packageId}"
}
EOF
}

# Change package state to Uploaded
echo "https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packages/${packageId}"
echo $(generateUploadedPackageRequestBody)
packageInfo=$(curl -X PUT \
  -H "Authorization: Bearer ${token}" \
  -H "accept: application/json" \
  -H "Content-Type: application/json" \
  -d "$(generateUploadedPackageRequestBody)" \
  https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packages/${packageId} | jq .)

if [ $? -ne 0 ]; then
    echo "Error happens when updating package state to Uploaded" >&2
    exit 1
fi

echo "change new created package's state to Uploaded" >&2
echo $packageInfo | jq . >&2

# check if package state is Processed, retry when it is InProcessing, exit when it is ProcessFailed
attempt=0
state="InProcessing"
while [ $state = "InProcessing" ] && [ $attempt -le 10 ]; do
    packageInfo=$(curl -X GET \
    https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packages/${packageId} \
    -H "Authorization: Bearer ${token}" \
    -H 'accept: application/json' | jq .)

    if [ $? -ne 0 ]; then
        echo "Error happens when getting package state" >&2
        exit 1
    fi

    echo "wait for the uploaded package to be processed" >&2
    echo $packageInfo | jq .

    state=$(echo $packageInfo | jq -r '.state')

    # if state is ProcessFailed exit 1
    if [ $state = "ProcessFailed" ]; then
        echo "Error happens when processing uploaded package" >&2
        exit 1
    elif [ $state = "InProcessing" ]; then
        echo "Package is under processing" >&2
        attempt=$((attempt+1))
        sleep 10s
    elif [ $state = "Processed" ]; then
        echo "Package processing is complted" >&2
        break
    fi
done

if [ $state != "Processed" ]; then
    echo "Package state is: ${state}, something could went wrong" >&2
    exit 1
fi

# Get package draft configuration
packageConfiguration=$(curl -X GET \
  "https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packageConfigurations/getByInstanceID(instanceID=${draftInstanceId})" \
  -H "Authorization: Bearer ${token}" \
  -H "accept: application/json" | jq .)

echo "get package draft configuration" >&2
echo $packageConfiguration | jq . >&2

if [ $? -ne 0 ]; then
    echo "Error happens when getting draft configuration" >&2
    exit 1
fi

configuration=$(echo $packageConfiguration | jq -r '.value[0]')
configurationId=$(echo $packageConfiguration | jq -r '.value[0].id')
dataEtag=$(echo $packageConfiguration | jq -r '.value[0] | .["@odata.etag"]')

# Change update package reference
generateUpdatePackageReferenceRequestBody()
{
    cat <<EOF
{
    "resourceType": "AzureSolutionTemplatePackageConfiguration",
    "version": "${artifactVersion}",
    "packageReferences": [
        {
            "type": "AzureApplicationPackage",
            "value": "${packageId}"
        }
    ],
    "id": "${configurationId}"
}
EOF
}

# Update package reference
curl -X PUT \
  "https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packageconfigurations/${configurationId}" \
  -H "Authorization: Bearer ${token}" \
  -H "accept: application/json" \
  -H "Content-Type: application/json" \
  -H "If-Match: ${dataEtag}" \
  -d "$(generateUpdatePackageReferenceRequestBody)" | jq .

# Validate response
if [ $? -ne 0 ]; then
    echo "Error happens when updating package reference in configuration" >&2
    exit 1
fi