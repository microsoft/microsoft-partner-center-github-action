#!/bin/bash -l

export clientId=$1
export secretValue=$2
export tenantId=$3
export offerName=$4
export planName=$5
export offerType=$6
export filePath=$7
export artifactVersion=$8
export imageVersionNumber=${9}
export imageType=${10}
export osDiskSasUrl=${11}
export dataDiskSasUrl=${12}
export operatingSystemFamily=${13}
export operatingSystemType=${14}



validate_status() {
    if [ $? -ne 0 ]; then
        echo "$@" >&2
        echo "Errors happen, exit 1."
        exit 1
    fi
}

############ Application Offer methods start #################

# Get product by name
application_get_product_id() {
    echo "curl --fail -X GET \
    https://api.partner.microsoft.com/v1.0/ingestion/products \
    -H \"Authorization: Bearer ${token}\" \
    -H \"accept: application/json\""

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
application_get_variant_id() {
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
application_get_draft_instance_id() {
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
application_generateNewPackageRequestBody()
{
    cat <<EOF
{
    "resourceType": "AzureApplicationPackage",
    "fileName": "${fileName}"
}
EOF
}

application_create_new_package() {
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
application_upload_artifact() {
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
application_generateUploadedPackageRequestBody()
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
application_update_package_state_to_uploaded() {
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
application_wait_for_package() {
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
application_get_package_draft_config() {
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
application_generateUpdatePackageReferenceRequestBody()
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
application_update_package_reference() {
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

application_generate_partner_center_token() {
    tokenJson=$(curl -X POST -d "grant_type=client_credentials" -d "client_id=${clientId}" -d "client_secret=${secretValue}" -d "resource=https://api.partner.microsoft.com" https://login.microsoftonline.com/${tenantId}/oauth2/token)
    token=$(echo ${tokenJson} | jq -r '.access_token')
    export token=$token
}

############ Application Offer methods end #################

############ VM Offer methods start #################
vm_generate_partner_center_token() {
    echo "Start generating Partner Center token."
    tokenJson=$(curl --fail -X POST -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=client_credentials&client_id=${clientId}&client_secret=${secretValue}&resource=https://graph.microsoft.com" https://login.microsoftonline.com/${tenantId}/oauth2/token)
    validate_status "generate partner center token"
    token=$(echo ${tokenJson} | jq -r '.access_token')
    export token=$token
    echo "Partner Center token generated."
}

vm_get_product_durable_id() {
    echo "Start getting product durable ID by offer name."
    productJson=$(curl --fail -X GET "https://graph.microsoft.com/rp/product-ingestion/product?externalId=${offerName}" -H "Authorization: Bearer ${token}")
    validate_status "get product duration ID"
    productDurableId=$(echo ${productJson} | jq -r '.value[0].id')
    echo "Product durable ID got."
}

vm_get_plan_durable_id() {
    echo "Start getting plan durable ID by plan name."
    planJson=$(curl --fail -X GET "https://graph.microsoft.com/rp/product-ingestion/plan?product=${productDurableId}&externalId=${planName}" -H "Authorization: Bearer ${token}")
    validate_status "get plan duration ID"
    planDurableId=$(echo ${planJson} | jq -r '.value[0].id')
    echo "Plan durable ID got."
}

vm_get_all_tech_configurations() {
    echo "Start getting all technical configurations under the plan."
    IFS='/' read -r -a productArray <<< "$productDurableId"
    productIdWithoutPrefix="${productArray[1]}"
    IFS='/' read -r -a planArray <<< "$planDurableId"
    planIdWithoutPrefix="${planArray[2]}"
    techConfigJson=$(curl --fail -X GET "https://graph.microsoft.com/rp/product-ingestion/virtual-machine-plan-technical-configuration/${productIdWithoutPrefix}/${planIdWithoutPrefix}" -H "Authorization: Bearer ${token}")
    validate_status "get all technical configurations"
    echo "All technical configurations under the plan got."
}

vm_get_all_current_all_image_versions() {
    imageVersions=$(echo ${techConfigJson} | jq -r '.vmImageVersions')
}

vm_applend_new_draft_tech_configuration() {
    echo "Start updating technical configurations."
    # Mark existing draft as delete
    imageVersionsFiltered=$(echo ${imageVersions} | jq -r 'map(if .lifecycleState == "deprecated" then . else .lifecycleState = "deleted" end)')
    # Append new draft image version
    imageVersionsAppended=$(echo ${imageVersionsFiltered} | jq --arg vNum "${imageVersionNumber}" --arg type "${imageType}" --arg osUrl "${osDiskSasUrl}" --arg dataUrl "${dataDiskSasUrl}" '.|=.+[{"versionNumber":$vNum,"vmImages":[{"imageType":$type,"source":{"sourceType":"sasUri","osDisk":{"uri":$osUrl},"dataDisks":[{"lunNumber":0,"uri":$dataUrl}]}}]}]')
    # Put things together to form the reqeust data
    requestData={\"\$schema\":\"https://product-ingestion.azureedge.net/schema/configure/2022-03-01-preview2\",\"resources\":[{\"\$schema\":\"https://product-ingestion.azureedge.net/schema/virtual-machine-plan-technical-configuration/2022-03-01-preview3\",\"product\":{\"externalId\":\"${offerName}\"},\"plan\":{\"externalId\":\"${planName}\"},\"operatingSystem\":{\"family\":\"${operatingSystemFamily}\",\"type\":\"${operatingSystemType}\"},\"skus\":[{\"imageType\":\"${imageType}\",\"skuId\":\"${planName}\"}],\"vmImageVersions\":${imageVersionsAppended}}]}
    requestDataCompact=$(echo $requestData | jq -c)
    # Post to Partner Center
    response=$(curl --fail -X POST 'https://graph.microsoft.com/rp/product-ingestion/configure' -H "Content-Type: application/json" -H "accept: application/json" -H "Authorization: Bearer ${token}" -d $requestDataCompact)
    validate_status "update configuration, add new draft technical configuration"
    # Extract job Id
    jobId=$(echo $response | jq -r '.jobId')
    echo "Technical configurations updated."
}

vm_check_configuration_status() {
    # check the job status
    attempt=0
    state="pending"
    while [ $state = "pending" ] && [ $attempt -le 10 ]; do
        echo "wait for the job to be processed" >&2
        jobStatusOutput=$(curl --fail -X GET \
            "https://graph.microsoft.com/rp/product-ingestion/configure/${jobId}/status" \
            -H "Content-Type: application/json" \
            -H "accept: application/json" \
            -H "Authorization: Bearer ${token}" | jq .)

        validate_status "get job state"

        jobStatusInfo=$(echo $jobStatusOutput | jq .)
        echo "current job status is: " >&2
        echo $jobStatusInfo | jq . >&2

        result=$(echo $jobStatusInfo | jq -r '.jobResult')

        # if state is failed exit 1
        if [ $result = "failed" ]; then
            echo "Error happens when processing job" >&2
            exit 1
        elif [ $result = "cancelled" ]; then
            echo "Job is cancelled" >&2
            exit 1
        elif [ $result = "pending" ]; then
            echo "Job is under processing" >&2
            attempt=$((attempt+1))
            sleep 10s
        elif [ $result = "succeeded" ]; then
            echo "Job processing succeeded" >&2
            break
        fi
    done

    if [ $result != "succeeded" ]; then
        echo "Job state is: ${result}, something could went wrong" >&2
        exit 1
    else
        echo "Job processing succeeded"
    fi

}

############ VM Offer methods end #################

if [ $offerType == "application_offer" ]; then
    application_generate_partner_center_token

    application_get_product_id

    application_get_variant_id

    application_get_draft_instance_id

    application_create_new_package

    application_upload_artifact

    application_update_package_state_to_uploaded

    application_wait_for_package

    application_get_package_draft_config

    application_update_package_reference
elif [ $offerType == "vm_image_offer" ]; then
    generate_partner_center_token

    get_product_durable_id

    get_plan_durable_id

    get_all_tech_configurations

    get_all_current_all_image_versions

    applend_new_draft_tech_configuration

    check_configuration_status
else
    echo "Unsupported offer type" >&2
    exit 1
fi

