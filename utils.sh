#! /bin/bash

tmpdir=$(mktemp -d)
echo "Temp DIR: $tmpdir"

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
    local sg=$(aws ec2 describe-instances --instance-ids ${ids} --query 'Reservations[*].Instances[*].SecurityGroups[*].GroupId' --region ${region} | uniq)
    [[ -z $sg ]] && echo "(sg) faild to open AWS port, do it manually" && return 0
    aws ec2 authorize-security-group-ingress --group-id ${sg} --protocol tcp --port 15150 --source-group ${sg} --region ${region} || echo "failed to open ports, try manually" && return 0
}
