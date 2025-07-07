#! /bin/bash

tmpdir=$(mktemp -d)

RED='\033[0;31m'
GREEN='\033[0;92m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

test_vars() {
    for i in "$@"; do
        [ -z "${!i}" ] && echo "\$$i is NOT set" && EXT=1
    done
    [[ -n $EXT ]] && return 1
    return 0
}

kube_apply() {
    local filename=$1
    envsubst < yamls/$filename | tee ${tmpdir}/$filename | oc apply -f-
}

add_auth() {
    local toadd=$1
    if [[ ! -f ${toadd} ]] || [[ $(jq < ${toadd} '[.auths ] | length') -eq 0 ]]; then
        echo "Invalid auth.json file to combine"
    fi
    echo "cleaning registries that may break Openshift's pulls"
    jq 'del(.auths."quay.io") | del(.auths."registry.redhat.io")' ${toadd} > $tmpdir/cleanedauth.json
    oc get -n openshift-config secret/pull-secret -o=jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq '.' > $tmpdir/orig-pull-secret.json
    jq -s '.[0] * .[1] ' $tmpdir/orig-pull-secret.json $tmpdir/cleanedauth.json > $tmpdir/combined.json
    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=$tmpdir/combined.json
    oc get -n openshift-config secret/pull-secret -o=jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq '.' || echo "Invalid pull-secret"
}

aws_open_port() {
    echo "#### open port 15150 in AWS ocp cluster"
    local region=$(oc get infrastructure -n cluster -o=jsonpath='{.items[0].status.platformStatus.aws.region}')
    [[ -z $region ]] && echo "(region) faild to open AWS port, do it manually" && return 0
    local infra_name=$(oc get infrastructure -n cluster -o=jsonpath='{.items[0].status.infrastructureName}')
    [[ -z $infra_name ]] && echo "(infra_name) faild to open AWS port, do it manually" && return 0
    local ids=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${infra_name}-worker*" --query 'Reservations[*].Instances[*].InstanceId' --output text --region ${region})
    [[ -z $ids ]] && echo "(ids) faild to open AWS port, do it manually" && return 0
    local sgs=($(aws ec2 describe-instances --instance-ids ${ids} --query 'Reservations[*].Instances[*].SecurityGroups[*].GroupId' --output text --region ${region}))
    [[ -z ${sgs[0]} ]] && echo "(sgs) faild to open AWS port, do it manually" && return 0
    for sg in "${sgs[@]}"; do
        aws ec2 authorize-security-group-ingress --group-id ${sg} --protocol tcp --port 15150 --source-group ${sg} --region ${region} || echo "failed to open ports, try manually" #&& return 0
    done
}

azure_attach_nat() {
    local peerpod_nat_gw=peerpod-nat-gw
    local peerpod_nat_gw_ip=peerpod-nat-gw-ip

    [[ -z ${AZURE_REGION} ]] && echo "getting region from cm" && \
      local AZURE_REGION=$(oc get configmap peer-pods-cm -n openshift-sandboxed-containers-operator -o jsonpath='{.data.AZURE_REGION}') && \
      [[ -z ${AZURE_REGION} ]] && echo "FAILED!!! to attach Azure nat, failed to get region" && return

    # Get the vnet configured
    local azure_rg=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}') && \
      echo "Azure RG: \"$azure_rg\"" || echo "FAILED!!! to attach Azure nat, failed to fetch Azure RG"

    local azure_vnet_name=$(az network vnet list -g "${azure_rg}" --query '[].name' -o tsv) && \
      echo "Azure vnet name: \"$azure_vnet_name\"" || echo "FAILED!!! to Attach azure nat, failed to get vnet"

    azure_subnet_id=$(az network vnet subnet list --resource-group "${azure_rg}" \
       --vnet-name "${azure_vnet_name}" --query "[].{Id:id} | [? contains(Id, 'worker')]" --output tsv) && \
       echo "Azure subnet-id: \"$azure_subnet_id\"" || echo "FAILED!!! to attach Azure nat, failed subnet-id"

    az network public-ip create -g "${azure_rg}" -n "${peerpod_nat_gw_ip}" -l "${AZURE_REGION}" \
      --sku Standard || echo "FAILED!!! to attach azure nat, failed to set public-id"
    az network nat gateway create -g "${azure_rg}" -l "${AZURE_REGION}" \
      --public-ip-addresses "${peerpod_nat_gw_ip}" -n "${peerpod_nat_gw}" || \
      echo "FAILED!!! to attach azure nat, failed to set nat getway"

    az network vnet subnet update --nat-gateway "${peerpod_nat_gw}" --ids "${azure_subnet_id}" || \
      echo "FAILED!!! to attach azure nat, failed to update vnet"
}

helpmsg() {
cat <<EOF
Usage: $0 [options]
   options:
    -a <auth.json>    Provide auth json file with credentials to brew/ci
    -c <catalog:tag>  Set custom CATALOG
    -C                CATALOG is set to default value
    -d                Debug
    -h                Print this help message
    -l                Create ubuntu libvirt podvm image, in LIBVIRT_POOL pool or "default" pool
    -r                Remove PeerPods
    -s                Run sleep app
    -v <a.b.c>        Porvide PeerPods version to install (used for CSV)
    -y                Automatically answer yes for all questions
EOF
rmdir $tmpdir
}

create_libvirt_ubuntu_image() {
    local url=quay.io/confidential-containers/podvm-generic-ubuntu-amd64
    local img_name=ubuntu.qcow2
    local pool=${LIBVIRT_POOL:-default}
    echo "image: ${tmpdir}/${img_name}, pool: ${pool}"
    cd ${tmpdir}

    curl https://github.com/confidential-containers/cloud-api-adaptor/blob/v0.8.0/podvm/hack/download-image.sh -o download-image.sh
    chmod +x ./download-image.sh
    ./download-image.sh ${url} ${tmpdir} -o ${img_name}

    virsh -c qemu:///system vol-create-as --pool ${pool} --name podvm-base.qcow2 --capacity 20G --allocation 2G --prealloc-metadata --format qcow2
    virsh -c qemu:///system vol-upload --vol podvm-base.qcow2 ${tmpdir}/${img_name} --pool ${pool} --sparse && \
    echo "Volume named podvm-base.qcow2 in the ${pool} pool"
    echo "    to delete volume run: \"virsh -c qemu:///system vol-delete podvm-base.qcow2 --pool ${pool}\""
    [[ -f ${tmpdir}/${img_name} ]] && rm ${tmpdir}/${img_name} && rm ${tmpdir}/download-image.sh
}

remove_peerpods() {
    echo "#### Deleting Hello Openshift..."
    oc delete all -l app=hello-openshift
    oc delete pod/sleep
    echo "#### Deleting KataConfig..."
    echo "Hack: run \"oc edit kataconfigs/example-kataconfig\" in another window and remove \"finalizers:\" and the line below."
    oc delete kataconfigs/example-kataconfig

    echo "#### Deleting Subscription..."
    oc delete Subscription/sandboxed-containers-operator -n openshift-sandboxed-containers-operator

    echo "#### Deleting OperatorGroup..."
    oc delete OperatorGroup/openshift-sandboxed-containers-operator -n openshift-sandboxed-containers-operator

    echo "#### Deleting Namespace..."
    oc delete ns openshift-sandboxed-containers-operator

    echo "#### Deleting CatalogSource..."
    oc delete CatalogSource/my-operator-catalog -n openshift-marketplace

    echo "!!! Delete cached bundle images in the Worker Nodes !!!"
}

remove_trustee() {
    oc delete kbsconfig kbsconfig -n trustee-operator-system || true
    oc delete subscription trustee-operator -n trustee-operator-system || true
    oc delete operatorgroup trustee-operator-group -n trustee-operator-system || true
    oc delete namespace trustee-operator-system || true
    oc delete CatalogSource trustee-operator-catalog -n openshift-marketplace || true
}

