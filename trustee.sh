#! /bin/bash
set -e

source utils.sh

while getopts "dhy" OPTION; do
    case $OPTION in
    d)
        set -x;;
    h)
        helpmsg
        exit 0;;
    y)
        YES=true;;
    *)
        echo "Incorrect options provided"
        helpmsg && exit 1;;
    esac
done

echo "Temp DIR: ${tmpdir}"

echo -e "${BLUE}####${NC} Creating Namespace..."
kube_apply trustee-namespace.yaml

echo -e "${BLUE}####${NC} Creating OperatorGroup..."
kube_apply trustee-og.yaml

echo -e "${BLUE}####${NC} Creating Subscription..."
kube_apply trustee-subscription.yaml

until oc get deployment.apps/trustee-operator-controller-manager -n trustee-operator-system  &> /dev/null; do
    echo -e "${BLUE}####${NC} Waiting for trutee csv..."
    sleep 5
done
oc wait --for=condition=Available=true  deployment.apps/trustee-operator-controller-manager --timeout=3m -n trustee-operator-system


echo -e "${BLUE}####${NC} Creating Route..."
oc create route edge --service=kbs-service --port kbs-port -n trustee-operator-system || true


echo -e "${BLUE}####${NC} Creating Auth Secret..."
openssl genpkey -algorithm ed25519 > ${tmpdir}/privateKey
openssl pkey -in ${tmpdir}/privateKey -pubout -out ${tmpdir}/publicKey
oc create secret generic kbs-auth-public-key --from-file=${tmpdir}/publicKey -n trustee-operator-system || echo "failed to set auth secret, probably exist already"
oc get secret/kbs-auth-public-key -n trustee-operator-system || error_exit "no auth key found"
echo -e "${BLUE}@@@@@@@@${NC}"
cat ${tmpdir}/privateKey
echo -e "${BLUE}@@@@@@@@${NC}"


echo -e "${BLUE}####${NC} Creating Trustee ConfigMap..."
kube_apply trustee-cm.yaml

echo -e "${BLUE}####${NC} Creating RVPS ConfigMap..."
kube_apply trustee-rvps-cm.yaml

echo -e "${BLUE}####${NC} Creating Custom Secrets to shere with clients..."
oc create secret generic kbsres1 --from-literal key1=key-one  --from-literal key2=key-two -n trustee-operator-system || echo "failed to set custom secret, probably exist already"

echo -e "${BLUE}####${NC} Creating permissive access control policy for resources..."
kube_apply trustee-resource-policy-dev.yaml

echo -e "${RED}####${NC} Skipping Attestation Policy (will use operator's default)..."

echo -e "${BLUE}####${NC} Creating Permissive container image signature verification policies..."
oc create secret generic security-policy --from-file=osc=yamls/containers-policy-insecureAcceptAnything.json  -n trustee-operator-system || echo "failed to set container image signature verification policies, probably exist already"

echo -e "${BLUE}####${NC} Creating KBSConfig (with NodePort)..."
kube_apply kbsconfig.yaml

echo -e "${BLUE}####${NC} Waiting all pods to be ready..."
oc wait --for=condition=Ready pod --all -n trustee-operator-system --timeout=60s
oc get pods -n trustee-operator-system

echo -e "${BLUE}####${NC} Get Trustee URL..."
nodePort=$(oc -n trustee-operator-system get service kbs-service -o=jsonpath={.spec.ports..nodePort})
nodeIP=$(oc get node -o wide | tail -1 | awk '/worker/{print $6}')
export TRUSTEE_URL=http://${nodeIP}:${nodePort}
echo -e "TRUSTEE_URL: ${RED}http://${nodeIP}:${nodePort}${NC}"

echo -e "${BLUE}####${NC} Make INITDATA..."
envsubst < yamls/initdata.toml | tee ${tmpdir}/initdata.toml

if [[ -n $YES ]] || (read -r -p "Apply initdata? [y/N] " && [[ "$REPLY" =~ ^[Yy]$ ]]) ; then
    INITDATA=$(cat ${tmpdir}/initdata.toml | gzip | base64 -w0)
    oc get cm peer-pods-cm -n openshift-sandboxed-containers-operator || error_exit "not peer-pods cm to set initdata"
    oc patch cm peer-pods-cm -n openshift-sandboxed-containers-operator --type merge -p "{\"data\":{\"INITDATA\":\"$INITDATA\"}}"
    oc set env ds/osc-caa-ds -n openshift-sandboxed-containers-operator REBOOT="$(date)"
fi

