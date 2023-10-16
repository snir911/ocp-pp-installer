#! /bin/bash

echo "#### Deleting Hello Openshift..."
oc delete all -l app=hello-openshift

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
