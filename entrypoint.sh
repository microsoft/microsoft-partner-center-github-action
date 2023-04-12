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

if [ $offerType == "application_offer" ]; then
    ./applicationoffer.sh $offerName $planName $filePath $artifactVersion $clientId $secretValue $tenantId
elif [ $offerType == "vm_image_offer" ]; then
    ./vmimageoffer.sh $clientId $secretValue $tenantId $offerName $planName $imageVersionNumber $imageType $osDiskSasUrl $dataDiskSasUrl $operatingSystemFamily $operatingSystemType
else
    echo "Unsupported offer type" >&2
    exit 1
fi

