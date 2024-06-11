 #!/usr/bin/env bash

fail() {
    RED='\033[0;31m'
    NC='\033[0m'
    echo -e "${RED}\nScript execution failed: $1\n\n${NC}"
    exit 33
}
# Start Region: Set user inputs

export location='eastus'

export applianceSubscriptionId='4e090658-58de-4b9f-98f6-f87362cc941a'
export applianceResourceGroupName='CIS_Framework'
export applianceName='MS-DEF-ARC'

export customLocationSubscriptionId='4e090658-58de-4b9f-98f6-f87362cc941a'
export customLocationResourceGroupName='CIS_Framework'
export customLocationName='MS-DEF-ARC-Location'

export vCenterSubscriptionId='4e090658-58de-4b9f-98f6-f87362cc941a'
export vCenterResourceGroupName='CIS_Framework'
export vCenterName='MS-DEF-ARC-vCenter'

export enableAKS='false'

# End Region: Set user inputs

usageMsg='Usage ./arcvmware-setup.sh [--force]'
[[ $# -le 1 ]] || fail "$usageMsg"
[[ $# -eq 0 ]] || [[ $1 == '--force' ]] || fail "$usageMsg"
forceApplianceRun=0
if [[ -n "$1" ]]; then
    forceApplianceRun=1
fi

Http_Proxy=''
Https_Proxy=''
No_Proxy=''
Proxy_CA_Cert_Path=''

confirmationPrompt() {
    msg=$1
    input=""
    echo -e "$msg"
    while [ "$input" != "y" ] && [ "$input" != "Y" ] && [ "$input" != "n" ] && [ "$input" != "N" ]; do
        printf "y/n? "
        read -r input
    done
    if [ "$input" = "y" ] || [ "$input" = "Y" ]; then
        return 0
    else
        return 1
    fi
}

logFile="arcvmware-output.log"

logH1() {
    msg=$1
    GREEN='\033[0;32m'
    NC='\033[0m'
    pattern=$(printf '0-%.0s' {1..40})
    spacelen=$((40 - ${#msg} / 2 ))
    spaces=$(printf ' %.0s' $(seq 1 ${spacelen}))
    msgFull="\n \n ${pattern} \n $spaces $msg \n ${pattern} \n \n"
    echo -e "${GREEN}${msgFull}${NC}"
    echo -e "${msgFull}" >> $logFile
}

logH2() {
    msg=$1
    PURPLE='\033[0;35m'
    NC='\033[0m'
    msgFull="==> $msg\n"
    echo -e "${PURPLE}${msgFull}${NC}"
    echo -e "${msgFull}" >> $logFile
}

logText() {
    msg=$1
    echo -e "$msg\n"
    echo -e "$msg\n" >> $logFile
}

logWarn() {
    msg=$1
    YELLOW='\033[0;33m'
    NC='\033[0m'
    msgFull="Warning: $msg"
    echo -e "${YELLOW}${msgFull}${NC}"
    echo -e "${msgFull}" >> $logFile
}

createRG() {
    subscriptionId=$1
    rgName=$2
    group=$(az group show --subscription "$subscriptionId" -n "$rgName")
    if [ -z "$group" ]; then
        echo "Resource Group $rgName does not exist. Trying to create the resource group"
        az group create --subscription "$subscriptionId" -l "$location" -n "$rgName"
    fi
}

azVersionToInt() {
    version=$1
    awk -F. '{ print ($1*1000000)+($2*1000+$3) }' <<< "$version"
}

evaluateForceFlag() {
    resource_config_file_path="$PWD/$applianceName-resource.yaml"
    infra_config_file_path="$PWD/$applianceName-infra.yaml"
    appliance_config_file_path="$PWD/$applianceName-appliance.yaml"

    missing_files=()
    [[ -f "$resource_config_file_path" ]] || missing_files+=("$resource_config_file_path")
    [[ -f "$infra_config_file_path" ]] || missing_files+=("$infra_config_file_path")
    [[ -f "$appliance_config_file_path" ]] || missing_files+=("$appliance_config_file_path")

    missing_file_count=${#missing_files[@]}

    if [ "$missing_file_count" -eq 0 ]; then
        # If all the config files are present and the appliance is not in running state,
        # we always run with --force flag.
        logText "Using --force flag as all the required config files are present."
        forceApplianceRun=1
        return
    fi

    if [ "$missing_file_count" -eq 3 ]; then
        if [ "$forceApplianceRun" -eq 1 ]; then
            # If no config files are found, it might indicate that the script hasn't been
            # executed in the current directory to create the Azure resources before.
            # We let 'az arcappliance run' command handle the force flag.
            logText "Warning: None of the required config files are present."
        fi
        return
    fi

    if [ "$forceApplianceRun" -eq 1 ]; then
        # Handle missing config files occuring due to createconfig failure.
        missing_msg=$(printf "%s\n" "${missing_files[@]}")
        logText "Ignoring --force flag as one or more of the required config files are missing."
        msg=$(printf "Missing configuration files:\n%s\n" "$missing_msg")
        logText "$msg"
    fi
    forceApplianceRun=0
}

vcFqdnKey="vCenterFqdn"
vcPortKey="vCenterPort"
vcAddressKey="vCenterAddress"
vcUsernameKey="vCenterUsername"
vcPasswordKey="vCenterPassword"
declare -A vcenterDetails

function fetchVcenterDetails {
    if [[ -n "${vcenterDetails[$vcAddressKey]}" &&
          -n "${vcenterDetails[$vcUsernameKey]}" &&
          -n "${vcenterDetails[$vcPasswordKey]}" ]]; then
        return
    fi

    while true; do
        vcenterDetailsMsg="
Provide vCenter details.
Enter the FQDN or IP Address in the format 'FQDN:PORT' or 'IP:PORT'. If the port is not specified, the default port 443 will be used.
    * For example, if your vCenter URL is https://vcenter.contoso.com/ then enter vcenter.contoso.com
    * If your vCenter URL is http://10.11.12.13:9090/ then enter 10.11.12.13:9090
Enter full vCenter username. If your username is associated with a domain, please use one of the following formats: domain\username or username@domain.
"
        logWarn "${vcenterDetailsMsg}"
        
        while true; do
            if [[ -n "${vcenterDetails[$vcAddressKey]}" ]]; then
                address="${vcenterDetails[$vcAddressKey]}"
                break
            fi
            read -r -p "Please enter vCenter FQDN or IP Address: " address
            if [[ -z "$address" ]]; then
                echo "FQDN or IP Address cannot be empty. Please try again."
                continue
            fi
            
            # Check if https:// or http:// is present in the address or it ends with a slash
            if [[ "$address" =~ ^https?:// || "$address" == */ ]]; then
                echo "Please enter only the FQDN or IP Address. Do not include https:// or http:// in the address or end the address with a slash."
                continue
            fi
            
            # Split the address into FQDN/IP and port, with the last colon as the separator
            fqdn="${address%:*}"
            port="${address##*:}"
            
            # If port is not specified, use default port 443
            if [[ "$port" == "$address" ]]; then
                port="443"
            fi
            
            # Check if the port is a number
            if ! [[ "$port" =~ ^[0-9]+$ ]]; then
                echo "Port must be a number. Please try again."
                continue
            fi
            break
        done
        
        while true; do
            if [[ -n "${vcenterDetails[$vcUsernameKey]}" ]]; then
                username="${vcenterDetails[$vcUsernameKey]}"
                break
            fi
            read -r -p "Please enter vCenter username: " username
            if [[ -z "$username" ]]; then
                echo "Username cannot be empty. Please try again."
                continue
            fi
            break
        done
        
        while true; do
            if [[ -n "${vcenterDetails[$vcPasswordKey]}" ]]; then
                break
            fi
            read -r -s -p "Please enter vCenter password: " password
            # Display asterisks with the same length as the password
            echo "${password//?/*}"
            read -r -s -p "Please confirm vCenter password: " confirmPassword
            echo "${confirmPassword//?/*}"
            if [[ -z "$password" ]]; then
                echo "Password cannot be empty. Please try again."
                continue
            elif [[ "$password" != "$confirmPassword" ]]; then
                echo "Passwords do not match. Please try again."
            else
                break
            fi
        done
        
        read -r -p "Confirm vCenter details? [Y/n]: " confirm
        if [[ -z "$confirm" || "$confirm" =~ ^(yes|y)$ ]]; then
            vcenterDetails[$vcAddressKey]="$address"
            vcenterDetails[$vcFqdnKey]="$fqdn"
            vcenterDetails[$vcPortKey]="$port"
            vcenterDetails[$vcUsernameKey]="$username"
            vcenterDetails[$vcPasswordKey]="$password"
            break
        fi
    done
}

logH1 "Step 1/5: Setting up the current workstation"
logH2 "Installing az cli extensions for Arc"

if confirmationPrompt "Is the current workstation behind a proxy?"; then
    [[ -z "$Http_Proxy" ]] && read -r -p "HTTP proxy: " Http_Proxy
    [[ -z "$Https_Proxy" ]] && read -r -p "HTTPS proxy: " Https_Proxy
    [[ -z "$No_Proxy" ]] && read -r -p "No proxy(comma separated): " No_Proxy
    [[ -z "$Proxy_CA_Cert_Path" ]] && read -r -p "Proxy CA cert path (Press enter to skip): " Proxy_CA_Cert_Path
fi

export http_proxy=$Http_Proxy
export https_proxy=$Https_Proxy
export no_proxy=$No_Proxy
export HTTP_PROXY=$Http_Proxy
export HTTPS_PROXY=$Https_Proxy
export NO_PROXY=$No_Proxy
if [ -n "$Proxy_CA_Cert_Path" ]
then
    export REQUESTS_CA_BUNDLE=$Proxy_CA_Cert_Path
fi

supportMsg="\nPlease reach out to arc-vmware-feedback@microsoft.com or create a support ticket for Arc enabled VMware vSphere in Azure portal."

azVersionMinimum="2.51.0"
azVersionInstalled=$(az version --query '"azure-cli"' -o tsv)
[ -n "$azVersionInstalled" ] || fail "azure-cli is not installed. Please install the latest version from https://docs.microsoft.com/cli/azure/install-azure-cli"
minVer=$(azVersionToInt $azVersionMinimum)
installedVer=$(azVersionToInt "$azVersionInstalled")
[[ "$installedVer" -ge "$minVer" ]] || fail "We recommend to use the latest version of Azure CLI. The minimum required version is $azVersionMinimum.\nPlease upgrade az by running 'az upgrade' or download the latest version from https://docs.microsoft.com/cli/azure/install-azure-cli."

az extension add --allow-preview false --upgrade --name arcappliance
az extension add --allow-preview false --upgrade --name k8s-extension
az extension add --allow-preview false --upgrade --name customlocation
az extension add --allow-preview false --upgrade --name connectedvmware

logH2 "Logging into azure"

azLoginMsg="Please login to Azure CLI.\n"
azLoginMsg+="\t* If you're running the script for the first time select yes.\n"
azLoginMsg+="\t* If you've recently logged in to az while running the script, you can select no.\n\n"
azLoginMsg+="Confirm login to azure cli?"
confirmationPrompt "$azLoginMsg" && az login --use-device-code -o none

az account set -s "$applianceSubscriptionId" || fail "The default subscription for the az cli context could not be set."

logH1 "Step 1/5: Workstation was set up successfully"

createRG "$applianceSubscriptionId" "$applianceResourceGroupName"

logH1 "Step 2/5: Creating the Arc resource bridge"

mkdir -p "$HOME/.kva/.ssh" && chmod +x "$HOME/.kva/.ssh"

applianceObj=$(az arcappliance show --debug --subscription "$applianceSubscriptionId" --resource-group "$applianceResourceGroupName" --name "$applianceName" --query "{id:id, status:status}" -o tsv 2>> $logFile)
applianceId=""
applianceStatus=""

if [[ -n "$applianceObj" ]]; then
    applianceId=$(echo "$applianceObj" | awk '{print $1}')
    applianceStatus=$(echo "$applianceObj" | awk '{print $2}')
fi

invokeApplianceRun=1

if [[ "$applianceStatus" == "Running" ]]; then
    invokeApplianceRun=0
    if [[ "$forceApplianceRun" -eq 1 ]]; then
        msg="The resource bridge is already running. Running with --force flag will delete the existing resource bridge and create a new one. Do you want to continue?"
        confirmationPrompt "$msg" && invokeApplianceRun=1
    fi
else
    evaluateForceFlag
    if [[ "$forceApplianceRun" -eq 0 ]]; then
        deleteAppl=0
        if [[ "$applianceStatus" == "WaitingForHeartbeat" ]]; then
            deleteAppl=1
        elif [[ -n "$applianceStatus" ]]; then
            msg="An existing Arc resource bridge is already present in Azure (status: $applianceStatus). Do you want to delete it?"
            confirmationPrompt "$msg" && deleteAppl=1
        fi

        if [[ "$deleteAppl" -eq 1 ]]; then
            logText "Deleting the existing Arc resource bridge"
            az resource delete --debug --ids "$applianceId" --yes 2>> $logFile
        fi
    fi
fi

if [[ "$invokeApplianceRun" -eq 1 ]]; then
    fetchVcenterDetails
    forceParam=()
    if [ "$forceApplianceRun" -eq 1 ]; then
        forceParam=("--force")
    fi
    az arcappliance run vmware --tags "" "${forceParam[@]}" --subscription "$applianceSubscriptionId" --resource-group "$applianceResourceGroupName" --name "$applianceName" --location "$location" --address "${vcenterDetails[$vcAddressKey]}" --username "${vcenterDetails[$vcUsernameKey]}" --password "${vcenterDetails[$vcPasswordKey]}"
else
    logText "The Arc resource bridge is already running. Skipping the creation of resource bridge."
fi

applianceObj=$(az arcappliance show --debug --subscription "$applianceSubscriptionId" --resource-group "$applianceResourceGroupName" --name "$applianceName" --query "{id:id, status:status}" -o tsv 2>> $logFile)
applianceId=""
applianceStatus=""

if [[ -n "$applianceObj" ]]; then
    applianceId=$(echo "$applianceObj" | awk '{print $1}')
    applianceStatus=$(echo "$applianceObj" | awk '{print $2}')
fi

if [[ -z "$applianceId" ]]; then
    # Appliance ARM resource is now created before the appliance VM.
    # So, this code path should not be hit.
    fail "Appliance creation has failed. $supportMsg"
fi

if [[ "$applianceStatus" == "WaitingForHeartbeat" ]]; then
    fail "Appliance VM creation failed. $supportMsg"
fi

logText "Waiting for the appliance to be ready..."
for i in {1..5}; do
    sleep 60
    applianceStatus=$(az resource show --debug --ids "$applianceId" --query 'properties.status' -o tsv 2>> $logFile)
    if [ "$applianceStatus" = "Running" ]; then
        break
    fi
    logText "Appliance is not ready yet, retrying... ($i/5)"
done
if [ "$applianceStatus" != "Running" ]; then
    fail "Appliance is not in running state. Current state: $applianceStatus. $supportMsg"
fi

logH1 "Step 2/5: Arc resource bridge is up and running"
logH1 "Step 3/5: Installing cluster extension"

validateCEState() {
    ceName=$1
    clusterExtensionId=$(az k8s-extension show --subscription "$applianceSubscriptionId" --resource-group "$applianceResourceGroupName" --name "$ceName" --cluster-type appliances --cluster-name "$applianceName" --query id -o tsv 2>> $logFile)
    if [ -z "$clusterExtensionId" ]; then
        fail "Cluster extension installation failed."
    fi
    clusterExtensionState=$(az resource show --debug --ids "$clusterExtensionId" --query 'properties.provisioningState' -o tsv 2>> $logFile)
    if [ "$clusterExtensionState" != "Succeeded" ]; then
        fail "Provisioning State of cluster extension is not succeeded. Current state: $clusterExtensionState. $supportMsg"
    fi
    echo "$clusterExtensionId"
}

az k8s-extension create --debug --subscription "$applianceSubscriptionId" --resource-group "$applianceResourceGroupName" --name azure-vmwareoperator --extension-type 'Microsoft.vmware' --scope cluster --cluster-type appliances --cluster-name "$applianceName" --config Microsoft.CustomLocation.ServiceAccount=azure-vmwareoperator 2>> $logFile

ceVmware="$(validateCEState azure-vmwareoperator)"

if [ "$enableAKS" == "true" ]; then
    logH2 "Installing Microsoft.HybridAKSOperator extension..."
    az k8s-extension create --debug --subscription "$applianceSubscriptionId" --resource-group "$applianceResourceGroupName" --name hybridaksopext --extension-type 'Microsoft.HybridAKSOperator' --release-train preview --version '0.4.5' --auto-upgrade-minor-version false --scope cluster --cluster-type appliances --cluster-name "$applianceName" --config Microsoft.CustomLocation.ServiceAccount='default' 2>> $logFile

    ceAks="$(validateCEState hybridaksopext)"
fi

logH1 "Step 3/5: Cluster extension installed successfully"
logH1 "Step 4/5: Creating custom location"

createRG "$customLocationSubscriptionId" "$customLocationResourceGroupName"

validateCLState() {
    clName=$1
    customLocationId=$(az customlocation show --subscription "$customLocationSubscriptionId" --resource-group "$customLocationResourceGroupName" --name "$clName" --query id -o tsv 2>> $logFile)
    if [ -z "$customLocationId" ]; then
        fail "Custom location creation failed."
    fi
    customLocationState=$(az resource show --debug --ids "$customLocationId" --query 'properties.provisioningState' -o tsv 2>> $logFile)
    if [ "$customLocationState" != "Succeeded" ]; then
        fail "Provisioning State of custom location is not succeeded. Current state: $customLocationState. $supportMsg"
    fi
    echo "$customLocationId"
}

normalizeCLName() {
    clName=$1
    echo "$clName" | tr '[:upper:]' '[:lower:]' | perl -pe 's/[^a-z0-9-]//g'
}

customLocationNamespace="$(normalizeCLName "$customLocationName")"
az customlocation create --debug --tags "" --subscription "$customLocationSubscriptionId" --resource-group "$customLocationResourceGroupName" --name "$customLocationName" --location "$location" --namespace "$customLocationNamespace" --host-resource-id "$applianceId" --cluster-extension-ids "$ceVmware" 2>> $logFile

customLocationId="$(validateCLState "$customLocationName")"

if [ "$enableAKS" == "true" ]; then
    logH2 "Creating custom location for AKS..."
    customLocationAksName="AKS-$customLocationName"
    customLocationAksNamespace="default"
    az customlocation create --debug --tags "" --subscription "$customLocationSubscriptionId" --resource-group "$customLocationResourceGroupName" --name "$customLocationAksName" --location "$location" --namespace "$customLocationAksNamespace" --host-resource-id "$applianceId" --cluster-extension-ids "$ceAks" 2>> $logFile

    _="$(validateCLState "$customLocationAksName")"
fi

logH1 "Step 4/5: Custom location created successfully"
logH1 "Step 5/5: Connecting to vCenter"
createRG "$vCenterSubscriptionId" "$vCenterResourceGroupName"

fetchVcenterDetails
az connectedvmware vcenter connect --tags "" --subscription "$vCenterSubscriptionId" --resource-group "$vCenterResourceGroupName" --name "$vCenterName" --location "$location" --custom-location "$customLocationId" --fqdn "${vcenterDetails[$vcFqdnKey]}" --port "${vcenterDetails[$vcPortKey]}" --username "${vcenterDetails[$vcUsernameKey]}" --password "${vcenterDetails[$vcPasswordKey]}"

vcenterId=$(az connectedvmware vcenter show --only-show-errors --subscription "$vCenterSubscriptionId" --resource-group "$vCenterResourceGroupName" --name "$vCenterName" --query id -o tsv 2>> $logFile)
if [ -z "$vcenterId" ]; then
    fail "Connect vCenter failed."
fi
vcenterState=$(az resource show --debug --ids "$vcenterId" --query 'properties.provisioningState' -o tsv 2>> $logFile)
if [ "$vcenterState" != "Succeeded" ]; then
    fail "Provisioning State of vCenter is not succeeded. Current state: $vcenterState. $supportMsg"
fi

logH1 "Step 5/5: vCenter was connected successfully"
logH1 "Your vCenter has been successfully onboarded to Azure Arc!"
logText "To continue onboarding and to complete Arc enabling your vSphere resources, view your vCenter resource in Azure portal.\nhttps://portal.azure.com/#resource${vcenterId}/overview"
