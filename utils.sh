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

