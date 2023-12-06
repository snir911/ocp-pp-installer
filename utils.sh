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
    oc get -n openshift-config secret/pull-secret -o=jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq '.' > $tmpdir/orig-pull-secret.json
    jq -s '.[0] * .[1] ' $tmpdir/orig-pull-secret.json ${toadd} > $tmpdir/combined.json
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
    local sg=$(aws ec2 describe-instances --instance-ids ${ids} --query 'Reservations[*].Instances[*].SecurityGroups[*].GroupId' --region ${region} --output text | uniq)
    [[ -z $sg ]] && echo "(sg) faild to open AWS port, do it manually" && return 0
    aws ec2 authorize-security-group-ingress --group-id ${sg} --protocol tcp --port 15150 --source-group ${sg} --region ${region} || echo "failed to open ports, try manually" && return 0
}

helpmsg() {
cat <<EOF
Usage: $0 [options]
   options:
    -a <auth.json>    Provide auth json file with credentials to brew/ci
    -d                Debug
    -h                Print this help message
    -l                Create ubuntu libvirt podvm image, in LIBVIRT_POOL pool or "default" pool
    -r                Remove PeerPods
    -s                Run sleep app
    -t <repo base>    Set IMAGE_TAG_BASE
    -v <a.b.c>        Porvide PeerPods version to install
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
