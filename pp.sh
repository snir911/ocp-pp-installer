#! /bin/bash
set -e

source utils.sh

DEFAULT_CATALOG="quay.io/openshift_sandboxed_containers/openshift-sandboxed-containers-operator-catalog:1.9.0-9"
[[ -f ${XDG_RUNTIME_DIR}/containers/auth.json ]] && AUTH_FILE=${XDG_RUNTIME_DIR}/containers/auth.json

while getopts "a:Ac:Cdhlrsv:y" OPTION; do
    case $OPTION in
    a)
        AUTH_FILE=$OPTARG;;
    c)
        export CATALOG=${OPTARG};;
    C)
        export CATALOG=${DEFAULT_CATALOG};;
    d)
        set -x;;
    h)
        helpmsg
        exit 0;;
    l)
        create_libvirt_ubuntu_image && exit 0
        exit 1;;
    r)
        remove_peerpods && exit 0;;
    s)
        kube_apply fedora-sleep.yaml
        exit 0;;
    v)
        VERSION=$OPTARG;;
    y)
        YES=true;;
    *)
        echo "Incorrect options provided"
        helpmsg && exit 1;;
    esac
done

echo "Temp DIR: ${tmpdir}"
if [[ -n $CATALOG ]]; then
    export SOURCE=my-operator-catalog
    echo -e "${RED}@@@ Using custum version @@@${NC}"
    echo -e "${RED}@${NC}CATALOG=${BLUE}${CATALOG}${NC}"
    echo -e "${RED}@${NC}AUTH_FILE=${BLUE}${AUTH_FILE}${NC}"
fi
export VERSION=${VERSION:-1.9.0}
export CSV=sandboxed-containers-operator.v${VERSION%%-*}
export SOURCE=${SOURCE:-redhat-operators}

echo -e "VERSION=${GREEN}${VERSION}${NC}"
echo -e  "CSV=${GREEN}${CSV}${NC}"
echo -e "SOURCE=${GREEN}${SOURCE}${NC}"
cld=$(oc get infrastructure -n cluster -o json | jq '.items[].status.platformStatus.type'  | awk '{print tolower($0)}' | tr -d '"' ) && cld=${cld//none/libvirt}
echo -e "${BLUE}####${NC} Cloud Provider is: ${RED}${cld}${NC} ${BLUE}####${NC}"
echo

[[ -n $YES ]] || (read -r -p "Continue? [y/N] " && [[ "$REPLY" =~ ^[Yy]$ ]]) || exit 0

[[ -n $CATALOG ]] && echo -e "${BLUE}####${NC} Creating ImageContentSourcePolicy..." && \
kube_apply images-mirror-set.yaml && sleep 10
#kube_apply mirrors.yaml && sleep 10

[[ -n $CATALOG ]] && echo -e "${BLUE}####${NC} Creating CatalogSource..." && \
kube_apply catalog-source.yaml && \
[[ -n $AUTH_FILE ]] && echo -e "${BLUE}####${NC} Adding auth credentials..." && add_auth $AUTH_FILE

echo -e "${BLUE}####${NC} Creating Namespace..."
kube_apply namespace.yaml

echo -e "${BLUE}####${NC} Creating OperatorGroup..."
kube_apply operator-group.yaml

echo -e "${BLUE}####${NC} Creating Subscription..."
kube_apply subscription.yaml

until oc get deployment.apps/controller-manager -n openshift-sandboxed-containers-operator &> /dev/null; do
    echo -e "${BLUE}####${NC} Waiting for controller-manager..."
    sleep 5
done
oc wait --for=condition=Available=true deployment.apps/controller-manager --timeout=3m -n openshift-sandboxed-containers-operator

# Fix wrong upstream variable
[[ -n $CATALOG ]] && echo -e "${BLUE}####${NC} Fixing wrong env variable..." && \
oc set env deployment.apps/controller-manager SANDBOXED_CONTAINERS_EXTENSION=sandboxed-containers -n openshift-sandboxed-containers-operator

echo -e "${BLUE}####${NC} Waiting for controller-manager..."
oc wait --for=condition=Available=true deployment.apps/controller-manager --timeout=20s -n openshift-sandboxed-containers-operator

#echo -e "${BLUE}####${NC} Setting Secrets"
#if [[ -n $YES ]] || (read -r -p "Create Secrets? [y/N] " && [[ "$REPLY" =~ ^[Yy]$ ]]) ; then
#    case $cld in
#        "aws")
#            kube_apply aws-cred-request.yaml
#            while ! kubectl get secret peer-pods-secret -n openshift-sandboxed-containers-operator; do echo "Waiting for secret."; sleep 1; done
#            oc get secret peer-pods-secret -n openshift-sandboxed-containers-operator -o yaml | sed -E 's/aws_([a-z]|_)*:/\U&/g' | oc replace -f -;;
#        "azure")
#            kube_apply azure-cred-request.yaml
#            while ! kubectl get secret peer-pods-secret -n openshift-sandboxed-containers-operator; do echo "Waiting for secret."; sleep 1; done
#            oc get secret peer-pods-secret -n openshift-sandboxed-containers-operator -o yaml | sed -E 's/azure_([a-z]|_)*:/\U&/g' | oc replace -f -;;
#        "libvirt"|"none")
#            echo "creating dummy secret for libvirt"
#	    oc create secret generic peer-pods-secret -n openshift-sandboxed-containers-operator || true
#            ;;
#        *)
#        echo "Supported options are aws, azure and libvirt" && exit 1;;
#    esac
#fi

if [[ $cld == libvirt ]]; then
    echo -e "${BLUE}####${NC} libvirt provider, skipping CM setting"
    LIBVIRT_URI=${LIBVIRT_URI:-qemu+ssh://${USER}@192.168.122.1/system?no_verify=1}
    LIBVIRT_NET=${LIBVIRT_NET:-default}
    LIBVIRT_POOL=${LIBVIRT_POOL:-default}
    echo "LIBVIRT_URI=${LIBVIRT_URI}, LIBVIRT_NET=${LIBVIRT_NET}, LIBVIRT_POOL=${LIBVIRT_POOL}"
    [[ -n $YES ]] || (read -r -p "Continue? [y/N] " && [[ "$REPLY" =~ ^[Yy]$ ]]) || exit 0
    kube_apply libvirt-cm.yaml
elif [[ -n $YES ]]; then
    echo -e "${BLUE}####${NC} Setting peer-pods-cm ConfigMap using defaulter"
    curl -sSL https://raw.githubusercontent.com/openshift/sandboxed-containers-operator/refs/heads/devel/scripts/cm-helpers/pp-cm-helper.sh | bash -s -- -y
elif (read -r -p "Create CM using the defaulter? [y/N] " && [[ "$REPLY" =~ ^[Yy]$ ]]) ; then
    bash -c "$(curl -sL https://raw.githubusercontent.com/openshift/sandboxed-containers-operator/refs/heads/devel/scripts/cm-helpers/pp-cm-helper.sh)"
fi

echo -e "${BLUE}####${NC} Misc configs"
case $cld in
   "aws")
        aws_open_port;;
    "azure")
        export AZURE_REGION
	azure_attach_nat
	ssh-keygen -f ${tmpdir}/id_rsa -N ""
	oc create secret generic ssh-key-secret -n openshift-sandboxed-containers-operator --from-file=id_rsa.pub=$tmpdir/id_rsa.pub --from-file=id_rsa=$tmpdir/id_rsa || true;;
    "libvirt")
        oc get secret ssh-key-secret -n openshift-sandboxed-containers-operator 2> /dev/null || true
        if [[ -n $YES ]] || (read -r -p "Creating key for libvirt and add to ~/.ssh/authorized_keys? [y/N] " && [[ "$REPLY" =~ ^[Yy]$ ]]) ; then
            ssh-keygen -f ${tmpdir}/id_rsa -N ""
            oc create secret generic ssh-key-secret -n openshift-sandboxed-containers-operator --from-file=id_rsa.pub=$tmpdir/id_rsa.pub --from-file=id_rsa=$tmpdir/id_rsa && \
            cat ${tmpdir}/id_rsa.pub >> ~/.ssh/authorized_keys
        fi
	;;
esac


[[ -n $YES ]] || (read -r -p "Enable Feature Gates!!!")

[[ -n $YES ]] || (read -r -p "Create KataConfig? [y/N] " && [[ "$REPLY" =~ ^[Yy]$ ]]) || exit 0

# Create kataconfig
echo -e "${BLUE}####${NC} Creating KataConfig..."
kube_apply kataconfig.yaml

until [ -n "$(oc get mcp -o=jsonpath='{.items[?(@.metadata.name=="kata-oc")].metadata.name}')" ]; do
    echo -e "${BLUE}####${NC} Waiting for kata-oc to be created..."
    oc get pods -n openshift-sandboxed-containers-operator
    sleep 10
done
echo -e "${BLUE}####${NC} Waiting for KataConfig to be created..."
oc wait --for=condition=Updating=false machineconfigpool/kata-oc --timeout=-1s


until oc get daemonset osc-caa-ds -n openshift-sandboxed-containers-operator &> /dev/null; do
    echo -e "${BLUE}####${NC} Waiting for osc-caa-ds to be created..."
    oc get pods -n openshift-sandboxed-containers-operator
    sleep 10
done
oc rollout status daemonset osc-caa-ds -n openshift-sandboxed-containers-operator --timeout=60s

echo "Peer Pods has been installed on your cluster"
oc get runtimeclass


echo -e "#### Run ${BLUE}\"$0 -s\"${NC} to run sample sleep pod ..."
#kube_apply hello-openshift.yaml
#oc expose service hello-openshift-service -l app=hello-openshift
