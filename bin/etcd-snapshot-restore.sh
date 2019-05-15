#!/usr/bin/env bash

set -o errexit
set -o pipefail

# example
# etcd-snapshot-restore.sh $path-to-snapshot

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

ASSET_DIR=./assets
SNAPSHOT_FILE="${ASSET_DIR}/backup/etcd/member/snap/db"

if [ "$1" != "" ]; then
  SNAPSHOT_FILE="$1"
fi

CONFIG_FILE_DIR=/etc/kubernetes
MANIFEST_DIR="${CONFIG_FILE_DIR}/manifests"
MANIFEST_STOPPED_DIR="${CONFIG_FILE_DIR}/manifests-stopped"
ETCD_VERSION=v3.3.10
ETCDCTL="${ASSET_DIR}/bin/etcdctl"
ETCD_DATA_DIR=/var/lib/etcd
ETCD_MANIFEST="${MANIFEST_DIR}/etcd-member.yaml"
ETCD_STATIC_RESOURCES="${CONFIG_FILE_DIR}/static-pod-resources/etcd-member"
STOPPED_STATIC_PODS="${ASSET_DIR}/tmp/stopped-static-pods"

source "/usr/local/bin/openshift-recovery-tools"

function run {
  init
  dl_etcdctl
  backup_manifest
  stop_static_pods
  stop_etcd
  stop_kubelet
  stop_all_containers
  backup_data_dir
  remove_data_dir
  restore_snapshot
  start_static_pods
  start_kubelet
}

run
