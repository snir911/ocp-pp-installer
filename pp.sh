#! /bin/bash
set -e

source utils.sh

while getopts "a:dht:ryv:" OPTION; do
    case $OPTION in
    a)
        AUTH_FILE=$OPTARG
        ;;
    d)
        set -x
        ;;
    h)
        helpmsg
        exit 0
        ;;
    t)
        IMAGE_TAG_BASE=$OPTARG
	;;
    r)
        remove_peerpods && exit 0
	;;
    y)
        YES=true
        ;;
    v)
        VERSION=$OPTARG
	;;
    *)
        echo "Incorrect options provided"
        helpmsg
        exit 1
	;;
    esac
done

export VERSION=${VERSION:-1.5.0-36}
export IMAGE_TAG_BASE=${IMAGE_TAG_BASE:=quay.io/openshift_sandboxed_containers/openshift-sandboxed-containers-operator}
export CSV=sandboxed-containers-operator.v${VERSION%%-*}
export CATALOG_TAG=${IMAGE_TAG_BASE}-catalog:v${VERSION}

echo "Temp DIR: ${tmpdir}"
echo "IMAGE_TAG_BASE=${IMAGE_TAG_BASE}"
echo "VERSION=${VERSION}"
echo "CSV=${CSV}"
echo "CATALOG_TAG=${CATALOG_TAG}"
echo

[[ -n $YES ]] || (read -r -p "Continue? [y/N]" && [[ "$REPLY" =~ ^[Yy]$ ]]) || exit 0

echo "#### Creating ImageContentSourcePolicy..."
kube_apply mirrors.yaml
sleep 10

echo "#### Creating CatalogSource..."
kube_apply catalog-source.yaml
[[ -n $AUTH_FILE ]] && echo "#### Adding auth credentials..." && add_auth $AUTH_FILE

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

echo "#### Setting Secrets"
case $cld in
   "aws")
        test_vars AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        kube_apply aws-secret.yaml;;
    "azure")
        test_vars AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_CLIENT_SECRET
        kube_apply azure-secret.yaml;;
    "libvirt")
        echo "TODO: add libvirt support" && exit 1;;
    *)
        echo "Supported options are aws, azure and libvirt" && exit 1;;
esac

if [[ -n $YES ]] || (read -r -p "Create CM using the defaulter? [y/N]" && [[ "$REPLY" =~ ^[Yy]$ ]]) ; then
    echo "#### Setting peer-pods-cm ConfigMap using defaulter"
    # check if cm already exist
    oc apply -f yamls/pp-cm-defaulter.yaml
    kubectl wait --for=condition=complete job/cm-defaulter -n openshift-sandboxed-containers-operator --timeout=60s
    if (( $? != 0 )); then
        echo "Defaulter failed to complete" && exit 1
    fi
fi

echo "#### Misc configs"
case $cld in
   "aws")
        aws_open_port;;
    "azure")
	ssh-keygen -f ${tmpdir}/id_rsa -N ""
	oc create secret generic ssh-key-secret -n openshift-sandboxed-containers-operator --from-file=id_rsa.pub=$tmpdir/id_rsa.pub --from-file=id_rsa=$tmpdir/id_rsa || true;;
esac

[[ -n $YES ]] || (read -r -p "Create KataConfig? [y/N]" && [[ "$REPLY" =~ ^[Yy]$ ]]) || exit 0

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

sleep 20
oc rollout status daemonset peerpodconfig-ctrl-caa-daemon -n openshift-sandboxed-containers-operator --timeout=60s

echo "Peer Pods has been installed on your cluster"


if (read -r -p "Deploy hello-openshift app? [y/N]" && [[ "$REPLY" =~ ^[Yy]$ ]]); then
    echo "#### Creating Hello Openshift..."
    kube_apply hello-openshift.yaml
    oc expose service hello-openshift-service -l app=hello-openshift
fi
