#! /bin/bash
set -e

source utils.sh

#export CSV=sandboxed-containers-operator.v1.4.8
#export VERSION=v1.4.8
#export IMAGE_TAG_BASE=quay.io/snir/osc-operator
export CSV=sandboxed-containers-operator.v1.5.0
export VERSION=1.5.0-34
export IMAGE_TAG_BASE=quay.io/openshift_sandboxed_containers/openshift-sandboxed-containers-operator
export CATALOG_TAG=${IMAGE_TAG_BASE}-catalog:${VERSION}
#export BUNDLE_TAG=${IMAGE_TAG_BASE}-bundle:${VERSION}


echo "#### Creating ImageContentSourcePolicy..."
kube_apply mirrors.yaml
sleep 10

echo "#### Creating CatalogSource..."
kube_apply catalog-source.yaml
[[ -n $1 ]] && echo "#### Adding auth credentials..." && add_auth $1

echo "#### Creating Namespace..."
kube_apply namespace.yaml

echo "#### Creating OperatorGroup..."
kube_apply operator-group.yaml

echo "#### Creating Subscription..."
kube_apply subscription.yaml

sleep 60

## Wait it is installed
echo "#### Waiting for controller-manager..."
oc wait --for=condition=Available=true deployment.apps/controller-manager --timeout=3m -n openshift-sandboxed-containers-operator

# Fix wrong upstream variable
echo "#### Fixing wrong env variable..."
oc set env deployment.apps/controller-manager SANDBOXED_CONTAINERS_EXTENSION=sandboxed-containers -n openshift-sandboxed-containers-operator

echo "#### Waiting for controller-manager..."
oc wait --for=condition=Available=true deployment.apps/controller-manager --timeout=20s -n openshift-sandboxed-containers-operator


cld=$(oc get infrastructure -n cluster -o json | jq '.items[].status.platformStatus.type'  | awk '{print tolower($0)}' | tr -d '"' )
echo "#### Cloud Provider is: $cld"

#exit 0
echo "#### Setting Secrets"
case $cld in
   "aws")
        test_vars AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        kube_apply aws-secret.yaml
        aws_open_port;;
    "azure")
        test_vars AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_CLIENT_SECRET
        kube_apply azure-secret.yaml
	ssh-keygen -f ${tmpdir}/id_rsa -N ""
	oc create secret generic ssh-key-secret -n openshift-sandboxed-containers-operator --from-file=id_rsa.pub=$tmpdir/id_rsa.pub --from-file=id_rsa=$tmpdir/id_rsa || true
	;;
    "libvirt")
	#kubectl create secret generic ssh-key-secret --from-file=id_rsa=${LIBVIRT_KEY} -n openshift-sandboxed-containers-operator
        echo "TODO: add libvirt support" && exit 1;;
    *)
        echo "Supported options are aws, azure and libvirt" && exit 1;;
esac

if [[ $cld != "libvirt" ]]; then
    echo "#### Setting peer-pods-cm ConfigMap using defaulter"
    # check if cm already exist
    oc apply -f yamls/pp-cm-defaulter.yaml
    kubectl wait --for=condition=complete job/cm-defaulter -n openshift-sandboxed-containers-operator --timeout=60s
    if (( $? != 0 )); then
        echo "Defaulter failed to complete" && exit 1
    fi
fi

echo "press any key to create KataConfig" && read

# Create kataconfig
echo "#### Creating KataConfig..."
kube_apply kataconfig.yaml

until [ -n "$(oc get mcp -o=jsonpath='{.items[?(@.metadata.name=="kata-oc")].metadata.name}')" ]
do
    echo "#### Waiting for kata-oc to be created..."
    oc get pods -n openshift-sandboxed-containers-operator
    sleep 10
done
echo "#### Waiting for KataConfig to be created..."
oc wait --for=condition=Updating=false machineconfigpool/kata-oc --timeout=-1s

oc rollout status daemonset peerpodconfig-ctrl-caa-daemon -n openshift-sandboxed-containers-operator --timeout=60s

echo "Peer Pods has been installed on your cluster"


echo "press any key to deploy hello-openshift app" && read
echo "#### Creating Hello Openshift..."
kube_apply hello-openshift.yaml
oc expose service hello-openshift-service -l app=hello-openshift
