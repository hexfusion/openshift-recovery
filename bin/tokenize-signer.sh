#!/usr/bin/env bash

set -o errexit
set -o pipefail

# example
# export KUBE_ETCD_SIGNER_SERVER=$(oc adm release info --image-for kube-etcd-signer-server --registry-config=./config.json)
# ./tokenize-signer.sh ip-10-0-134-97 

: ${KUBE_ETCD_SIGNER_SERVER:?"Need to set KUBE_ETCD_SIGNER_SERVER"}

usage () {
    echo 'Hostname required: ./tokenize-signer.sh ip-10-0-134-97'
    exit
}

if [ "$1" == "" ]; then
    usage
fi

MASTER_HOSTNAME=$1

ASSET_DIR=./assets
SHARED=/usr/local/share/openshift-recovery
TEMPLATE=$SHARED/template/kube-etcd-cert-signer.yaml.template
TEMPLATE_TMP=$ASSET_DIR/tmp/kube-etcd-cert-signer.yaml.stage1

source "/usr/local/bin/openshift-recovery-tools"

function run {
  init
  populate_template '__MASTER_HOSTNAME__' "$MASTER_HOSTNAME" "$TEMPLATE" "$TEMPLATE_TMP"
  populate_template '__KUBE_ETCD_SIGNER_SERVER__' "$KUBE_ETCD_SIGNER_SERVER" "$TEMPLATE_TMP" "$ASSET_DIR/manifests/kube-etcd-cert-signer.yaml"
}

run
