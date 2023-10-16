#! /bin/bash
set -e

source utils.sh

export VERSION=1.5.0-27
export IMAGE_TAG_BASE=quay.io/openshift_sandboxed_containers/openshift-sandboxed-containers-operator
export CATALOG_TAG=${IMAGE_TAG_BASE}-catalog:${VERSION}
export BUNDLE_TAG=${IMAGE_TAG_BASE}-bundle:${VERSION}


echo "#### Creating ImageContentSourcePolicy..."
kube_apply mirrors.yaml
sleep 10

echo "#### Creating CatalogSource..."
kube_apply catalog-source.yaml

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

echo "#### Setting peer-pods-secret Secret"
case $cld in
   "aws")
        test_vars AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
	kube_apply aws-secret.yaml;;
    "azure")
        test_vars AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_CLIENT_SECRET
	kube_apply azure-secret.yaml;;
    "libvirt")
	#kubectl create secret generic ssh-key-secret --from-file=id_rsa=${LIBVIRT_KEY} -n openshift-sandboxed-containers-operator
        echo "TODO: add libvirt support";;
    *)
        echo "Supported options are aws, azure and libvirt" && exit 1;;
esac

if [[ $cld != "libvirt" ]]; then
    echo "#### Setting peer-pods-cm ConfigMap using defaulter"
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

echo "#### Waiting for KataConfig to be created..."
sleep 60
oc wait --for=condition=Updating=false machineconfigpool/kata-oc --timeout=-1s

oc rollout status daemonset peerpodconfig-ctrl-caa-daemon -n openshift-sandboxed-containers-operator --timeout=60s

echo "Peer Pods has been installed on your cluster"


echo "press any key to deploy hello-openshift app" && read
echo "#### Creating Hello Openshift..."
kube_apply hello-openshift.yaml
oc expose service hello-openshift-service -l app=hello-openshift
