#!/bin/bash -l

export offerName=$1
export planName=$2
export filePath=$3
export artifactVersion=$4
export clientId=$5
export secretValue=$6
export tenantId=$7
export fileName=$(basename ${filePath})

validate_status() {
    if [ $? -ne 0 ]; then
        echo "$@" >&2
        echo "Errors happen, exit 1."
        exit 1
    fi
}

# Get product by name
get_product_id() {
    echo "curl --fail -X GET \
    https://api.partner.microsoft.com/v1.0/ingestion/products \
    -H \"Authorization: Bearer ${token}\" \
    -H \"accept: application/json\""

    echo "${token}"

    productsOutput=$(curl --fail -X GET \
    https://api.partner.microsoft.com/v1.0/ingestion/products \
    -H "Authorization: Bearer ${token}" \
    -H "accept: application/json")

    validate_status "Get offer list"

    products=$(echo $productsOutput | jq .)
    echo "first page of offers:" >&2
    echo $products | jq . >&2

    nextProductsLink=$(echo ${products} | jq -r '.nextLink')
    productId=$(echo ${products} | jq -r --arg offerName $offerName '.value | .[] | select(.name==$offerName) | .id')

    echo "offer finding result in first page: " $nextProductsLink $productId >&2

    # if cannot find name and has nextLink, try next 
    attempt=0
    while [ -z ${productId} ] && [ ! -z "${nextProductsLink}" ] && [ $attempt -le 10 ]; do
        echo https://api.partner.microsoft.com/${nextProductsLink}

        productsOutput=$(curl --fail -X GET \
        https://api.partner.microsoft.com/"${nextProductsLink}" \
        -H "Authorization: Bearer ${token}" \
        -H "accept: application/json")

        validate_status "Get offer list"

        products=$(echo $productsOutput | jq .)
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

    echo "productId is: " $productId
}

# Get variantId by plan name
get_variant_id() {
    variantId=""
    variantsOutput=$(curl --fail -X GET \
    https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/variants \
    -H "Authorization: Bearer ${token}" \
    -H "accept: application/json")

    validate_status "Get plan list"

    variants=$(echo $variantsOutput | jq .)
    echo "all plans under the offer: " >&2
    echo $variants | jq . >&2

    variantId=$(echo ${variants} | jq -r --arg planName $planName '.value | .[] | select(.friendlyName==$planName) | .id')

    validate_status "Get plan id by name"

    echo "variantId is: " $variantId
}

# Get draft instance id by variantId
get_draft_instance_id() {
    echo "Get draft instance id by variantId"
    draftInstanceId=""
    instancesOutput=$(curl --fail -X GET \
    "https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/branches/getByModule(module=Package)" \
    -H "Authorization: Bearer ${token}" \
    -H "accept: application/json")

    validate_status "Get draft instances"

    instances=$(echo $instancesOutput | jq .)
    echo "all draft plan instances under the offer:" >&2
    echo $instances >&2

    draftInstanceId=$(echo ${instances} | jq -r --arg variantId $variantId '.value | .[] | select(.variantID==$variantId) | .currentDraftInstanceID')

    validate_status "Get draftInstanceId"

    echo "draftInstanceId is: " $draftInstanceId
}

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

create_new_package() {
    packageInfoOutput=$(curl --fail -X POST \
    https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packages \
    -H "Authorization: Bearer ${token}" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -d "$(generateNewPackageRequestBody)")

    validate_status "Create new artifact upload task"

    packageInfo=$(echo $packageInfoOutput | jq .)
    echo "new created package info: " >&2
    echo $packageInfo >&2

    state=$(echo $packageInfo | jq -r '.state')
    fileSasUri=$(echo $packageInfo | jq -r '.fileSasUri')
    packageId=$(echo $packageInfo | jq -r '.id')
    dataEtag=$(echo $packageInfo | jq '.["@odata.etag"]')
}

# Upload file
upload_artifact() {
    echo "upload artifact starts" >&2
    dateNow=$(date -Ru | sed 's/\+0000/GMT/')
    azcliVersion="2018-03-28"

    curl --fail -X PUT -H "Content-Type: application/octet-stream" \
    -H "x-ms-date: ${dateNow}" \
    -H "x-ms-version: ${azcliVersion}" \
    -H "x-ms-blob-type: BlockBlob" \
    --data-binary "@${filePath}" \
    "${fileSasUri}"

    validate_status "upload artifact"

    echo "upload artifact ends" >&2
}

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
update_package_state_to_uploaded() {
    echo "https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packages/${packageId}"
    echo $(generateUploadedPackageRequestBody)
    packageInfoOutput=$(curl --fail -X PUT \
    -H "Authorization: Bearer ${token}" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -d "$(generateUploadedPackageRequestBody)" \
    https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packages/${packageId})

    validate_status "update package state to Uploaded"
}

# wait for package being processed
wait_for_package() {
    # check if package state is Processed, retry when it is InProcessing, exit when it is ProcessFailed
    attempt=0
    state="InProcessing"
    while [ $state = "InProcessing" ] && [ $attempt -le 10 ]; do
        echo "wait for the uploaded package to be processed" >&2
        packageInfoOutput=$(curl --fail -X GET \
        https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packages/${packageId} \
        -H "Authorization: Bearer ${token}" \
        -H 'accept: application/json' | jq .)

        validate_status "get package state"

        packageInfo=$(echo $packageInfoOutput | jq .)
        echo "current package info is: " >&2
        echo $packageInfo | jq . >&2

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
            echo "Package processing is completed" >&2
            break
        fi
    done

    if [ $state != "Processed" ]; then
        echo "Package state is: ${state}, something could went wrong" >&2
        exit 1
    else
        echo "package processing succeeded"
    fi
}


# Get package draft configuration
get_package_draft_config() {
    packageConfigurationOutput=$(curl --fail -X GET \
    "https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packageConfigurations/getByInstanceID(instanceID=${draftInstanceId})" \
    -H "Authorization: Bearer ${token}" \
    -H "accept: application/json" | jq .)

    validate_status "get draft configuration"

    packageConfiguration=$(echo $packageConfigurationOutput | jq .)

    echo "package draft configuration: " >&2
    echo $packageConfiguration | jq . >&2

    configuration=$(echo $packageConfiguration | jq -r '.value[0]')
    configurationId=$(echo $packageConfiguration | jq -r '.value[0].id')
    dataEtag=$(echo $packageConfiguration | jq -r '.value[0] | .["@odata.etag"]')
}

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
update_package_reference() {
    echo "Update package reference $(generateUpdatePackageReferenceRequestBody)" >&2
    curl --fail -X PUT \
    "https://api.partner.microsoft.com/v1.0/ingestion/products/${productId}/packageconfigurations/${configurationId}" \
    -H "Authorization: Bearer ${token}" \
    -H "accept: application/json" \
    -H "Content-Type: application/json" \
    -H "If-Match: ${dataEtag}" \
    -d "$(generateUpdatePackageReferenceRequestBody)"

    # Validate response
    validate_status "update package reference in draft configuration"
}

generate_partner_center_token() {
    curl -o token.json -X POST -d "grant_type=client_credentials" -d "client_id=${clientId}" -d "client_secret=${secretValue}" -d "resource=https://api.partner.microsoft.com" https://login.microsoftonline.com/${tenantId}/oauth2/token 
    tokenJson=$(curl -X POST -d "grant_type=client_credentials" -d "client_id=${clientId}" -d "client_secret=${secretValue}" -d "resource=https://api.partner.microsoft.com" https://login.microsoftonline.com/${tenantId}/oauth2/token)
    echo $tokenJson
    token=$(echo ${tokenJson} | jq -r '.access_token')
    echo $token
    export token=$token
}

generate_partner_center_token

get_product_id

get_variant_id

get_draft_instance_id

create_new_package

upload_artifact

update_package_state_to_uploaded

wait_for_package

get_package_draft_config

update_package_reference