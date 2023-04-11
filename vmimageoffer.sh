#!/bin/bash -l

export clientId=$1
export secretValue=$2
export tenantId=$3
export offerName=$4
export planName=$5
export imageVersionNumber=$6
export imageType=$7
export osDiskSasUrl=$8
export dataDiskSasUrl=$9
export operatingSystemFamily=${10}
export operatingSystemType=${11}

validate_status() {
    if [ $? -ne 0 ]; then
        echo "$@" >&2
        echo "Errors happen, exit 1."
        exit 1
    fi
}

generate_partner_center_token() {
    echo "Start generating Partner Center token."
    tokenJson=$(curl --fail -X POST -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=client_credentials&client_id=${clientId}&client_secret=${secretValue}&resource=https://graph.microsoft.com" https://login.microsoftonline.com/${tenantId}/oauth2/token)
    validate_status "generate partner center token"
    token=$(echo ${tokenJson} | jq -r '.access_token')
    export token=$token
    echo "Partner Center token generated."
}

get_product_durable_id() {
    echo "Start getting product durable ID by offer name."
    productJson=$(curl --fail -X GET "https://graph.microsoft.com/rp/product-ingestion/product?externalId=${offerName}" -H "Authorization: Bearer ${token}")
    validate_status "get product duration ID"
    productDurableId=$(echo ${productJson} | jq -r '.value[0].id')
    echo "Product durable ID got."
}

get_plan_durable_id() {
    echo "Start getting plan durable ID by plan name."
    planJson=$(curl --fail -X GET "https://graph.microsoft.com/rp/product-ingestion/plan?product=${productDurableId}&externalId=${planName}" -H "Authorization: Bearer ${token}")
    validate_status "get plan duration ID"
    planDurableId=$(echo ${planJson} | jq -r '.value[0].id')
    echo "Plan durable ID got."
}

get_all_tech_configurations() {
    echo "Start getting all technical configurations under the plan."
    IFS='/' read -r -a productArray <<< "$productDurableId"
    productIdWithoutPrefix="${productArray[1]}"
    IFS='/' read -r -a planArray <<< "$planDurableId"
    planIdWithoutPrefix="${planArray[2]}"
    techConfigJson=$(curl --fail -X GET "https://graph.microsoft.com/rp/product-ingestion/virtual-machine-plan-technical-configuration/${productIdWithoutPrefix}/${planIdWithoutPrefix}" -H "Authorization: Bearer ${token}")
    validate_status "get all technical configurations"
    echo "All technical configurations under the plan got."
}

get_all_current_all_image_versions() {
    imageVersions=$(echo ${techConfigJson} | jq -r '.vmImageVersions')
}

applend_new_draft_tech_configuration() {
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

check_configuration_status() {
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

generate_partner_center_token

get_product_durable_id

get_plan_durable_id

get_all_tech_configurations

get_all_current_all_image_versions

applend_new_draft_tech_configuration

check_configuration_status
