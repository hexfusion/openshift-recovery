#!/usr/bin/env bash

#set -e

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

usage () {
    echo 'Recovery server IP address required: ./script.sh 192.168.1.100'
    exit
}

if [ "$1" == "" ]; then
    usage
fi

RECOVERY_SERVER_IP=$1
ETCD_VERSION=v3.3.10
ETCDCTL=$ASSET_DIR/bin/etcdctl
ETCD_DATA_DIR=/var/lib/etcd

ASSET_DIR=./assets
CONFIG_FILE_DIR=/etc/kubernetes
ETCD_CLIENT_DIR="${CONFIG_FILE_DIR}/static-pod-resources/kube-apiserver-pod-1/secrets/etcd-client"
MANIFEST_DIR="${CONFIG_FILE_DIR}/manifests"
ETCD_MANIFEST="${MANIFEST_DIR}/etcd-member.yaml"
ETCD_CONFIG=/etc/etcd/etcd.conf

init() {
  ASSET_BIN=${ASSET_DIR}/bin
  if [ ! -d "$ASSET_BIN" ]; then
    echo "Creating asset directory ${ASSET_DIR}"
    for dir in {bin,tmp,shared,backup,templates}
    do
      /usr/bin/mkdir -p ${ASSET_DIR}/${dir}
    done
  fi
  dl_etcdctl $ETCD_VERSION
}

#backup etcd client certs
backup_etcd_client_certs() {
  echo "Trying to backup etcd client certs.."
  if [ -f "$ASSET_DIR/backup/etcd-ca-bundle.crt" ] && [ -f "$ASSET_DIR/backup/etcd-client.crt" ] && [ -f "$ASSET_DIR/backup/etcd-client.key" ]; then
     echo "etcd client certs already backed up and available $ASSET_DIR/backup/"
     return 0
  else
    for i in {1..10}; do
        SECRET_DIR="${CONFIG_FILE_DIR}/static-pod-resources/kube-apiserver-pod-${i}/secrets/etcd-client"
        CONFIGMAP_DIR="${CONFIG_FILE_DIR}/static-pod-resources/kube-apiserver-pod-${i}/configmaps/etcd-serving-ca"
        if [ -f "$CONFIGMAP_DIR/ca-bundle.crt" ] && [ -f "$SECRET_DIR/tls.crt" ] && [ -f "$SECRET_DIR/tls.key" ]; then
          cp $CONFIGMAP_DIR/ca-bundle.crt $ASSET_DIR/backup/etcd-ca-bundle.crt
          #cp $ASSET_DIR/backup/etcd-ca-bundle.crt ${CONFIG_FILE_DIR}/static-pod-resources/etcd-member
          cp $SECRET_DIR/tls.crt $ASSET_DIR/backup/etcd-client.crt
          #cp $ASSET_DIR/backup/etcd-client.crt ${CONFIG_FILE_DIR}/static-pod-resources/etcd-member
          cp $SECRET_DIR/tls.key $ASSET_DIR/backup/etcd-client.key
          #cp $ASSET_DIR/backup/etcd-client.key ${CONFIG_FILE_DIR}/static-pod-resources/etcd-member
          break
        else
          echo "$SECRET_DIR does not contain etcd client certs, trying next source .."
        fi
    done
   fi
}
# backup current etcd-member pod manifest
backup_manifest() {
  if [ -e "${ASSET_DIR}/backup/etcd-member.yaml" ]; then
    echo "etcd-member.yaml in found ${ASSET_DIR}/backup/"
  else
    echo "Backing up ${ETCD_MANIFEST} to ${ASSET_DIR}/backup/"
    cp ${ETCD_MANIFEST} ${ASSET_DIR}/backup/
  fi
}

# backup etcd.conf
backup_etcd_conf() {
  if [ -e "${ASSET_DIR}/backup/etcd.conf" ]; then
    echo "etcd.conf backup upready exists $ASSET_DIR/backup/etcd.conf"
  else
    echo "Backing up /etc/etcd/etcd.conf to ${ASSET_DIR}/backup/"
    cp /etc/etcd/etcd.conf ${ASSET_DIR}/backup/
  fi
}

backup_data_dir() {
  echo "Backing up etcd data-dir.."
  cp -rap ${ETCD_DATA_DIR}  $ASSET_DIR/backup/
}

backup_certs() {
  echo "Backing up etcd certs.."
  cp /etc/kubernetes/static-pod-resources/etcd-member/system\:etcd-* $ASSET_DIR/backup/
}

# stop etcd by moving the manifest out of /etcd/kubernetes/manifests
# we wait for all etcd containers to die.
stop_etcd() {
  BACKUP_DIR=/etc/kubernetes/manifests-stopped

  echo "Stopping etcd.."

  if [ ! -d "$BACKUP_DIR" ]; then
    mkdir $BACKUP_DIR
  fi

  if [ -e "$ETCD_MANIFEST" ]; then
    mv $ETCD_MANIFEST /etc/kubernetes/manifests-stopped/
  fi

  for name in {etcd-member,etcd-metric}
  do
    while [ "$(crictl pods -name $name | wc -l)" -gt 1  ]; do
      echo "Waiting for $name to stop"
      sleep 10
    done
  done
}


# generate a kubeconf like file for the cert agent to consume and contact signer.
gen_config() {
  CA=$(base64 $ASSET_DIR/backup/etcd-ca-bundle.crt | tr -d '\n')
  CERT=$(base64 $ASSET_DIR/backup/etcd-client.crt | tr -d '\n')
  KEY=$(base64 $ASSET_DIR/backup/etcd-client.key | tr -d '\n')

  read -r -d '' TEMPLATE << EOF
clusters:
- cluster:
    certificate-authority-data: ${CA}
    server: https://${RECOVERY_SERVER_IP}:9943
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: kubelet
  name: kubelet
current-context: kubelet
preferences: {}
users:
- name: kubelet
  user:
    client-certificate-data: ${CERT}
    client-key-data: ${KEY}
EOF
  echo "${TEMPLATE}" > ${CONFIG_FILE_DIR}/static-pod-resources/etcd-member/.recoveryconfig
}

# download and test etcdctl from upstream release assets
dl_etcdctl() {
  ETCD_VER=$1
  GOOGLE_URL=https://storage.googleapis.com/etcd
  DOWNLOAD_URL=${GOOGLE_URL}

  echo "Downloading etcdctl binary.."
  curl -s -L ${DOWNLOAD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o $ASSET_DIR/tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz \
    && tar -xzf $ASSET_DIR/tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz -C $ASSET_DIR/shared --strip-components=1 \
    && mv $ASSET_DIR/shared/etcdctl $ASSET_DIR/bin \
    && rm $ASSET_DIR/shared/etcd \
    && ETCDCTL_API=3 $ASSET_DIR/bin/etcdctl version
}

# add member cluster
etcd_member_add() {
  HOSTNAME=$(hostname)
  HOSTDOMAIN=$(hostname -d)
  ETCD_NAME=etcd-member-${HOSTNAME}.${HOSTDOMAIN}
  IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

  if [ -e $ASSET_DIR/backup/etcd/member/snap/db ]; then
    echo -e "Backup found removing exising data-dir"
    rm -rf $ETCD_DATA_DIR
  fi

  echo "Updating etcd membership.."

  APPEND_CONF=$(env ETCDCTL_API=3 $ETCDCTL --cert $ASSET_DIR/backup/etcd-client.crt --key $ASSET_DIR/backup/etcd-client.key --cacert $ASSET_DIR/backup/etcd-ca-bundle.crt \
    --endpoints ${RECOVERY_SERVER_IP}:2379 member add $ETCD_NAME --peer-urls=https://${IP}:2380)

   if [ $? -eq 0 ]; then
     echo "$APPEND_CONF"
     echo "$APPEND_CONF" | sed -e '/cluster/,+2d'
     cat "$APPEND_CONF" >> $ETCD_CONFIG
   else
     echo "$APPEND_CONF"
     exit 1
   fi
}

start_etcd() {
  echo "Starting etcd.."
  mv /etc/kubernetes/manifests-stopped/etcd-member.yaml $MANIFEST_DIR
}

download_cert_recover_template() {
  curl -s https://raw.githubusercontent.com/hexfusion/openshift-recovery/master/manifests/etcd-generate-certs.yaml.template -o $ASSET_DIR/templates/etcd-generate-certs.yaml.template
}

populate_template() {
  echo "Populating template.."
  DISCOVERY_DOMAIN=$(grep -oP '(?<=discovery-srv ).* ' $ASSET_DIR/backup/etcd-member.yaml )
  CLUSTER_NAME=$(echo ${DISCOVERY_DOMAIN} | grep -oP '^.*?(?=\.)')

  TEMPLATE=$ASSET_DIR/templates/etcd-generate-certs.yaml.template
  FIND='__ETCD_DISCOVERY_DOMAIN__'
  cp $TEMPLATE $ASSET_DIR/tmp
  REPLACE="${DISCOVERY_DOMAIN}"
  sed -i "s@${FIND}@${REPLACE}@" $ASSET_DIR/tmp/etcd-generate-certs.yaml.template
  mv $ASSET_DIR/tmp/etcd-generate-certs.yaml.template /etc/kubernetes/manifests-stopped/etcd-generate-certs.yaml
}

start_cert_recover() {
  echo "Starting etcd client cert recovery agent.."
  mv /etc/kubernetes/manifests-stopped/etcd-generate-certs.yaml $MANIFEST_DIR
}

verify_certs() {
  while [ "$(ls /etc/kubernetes/static-pod-resources/etcd-member/ | wc -l)" -lt 9  ]; do
    echo "Waiting for certs to generate.."
    sleep 10
  done
}

stop_cert_recover() {
  BACKUP_DIR=/etc/kubernetes/manifests-stopped

  echo "Stopping cert recover.."

  if [ -f "${CONFIG_FILE_DIR}/manifests/etcd-generate-certs.yaml" ]; then
    mv ${CONFIG_FILE_DIR}/manifests/etcd-generate-certs.yaml /etc/kubernetes/manifests-stopped/
  fi

  for name in {generate-env,generate-certs}
  do
    while [ "$(crictl pods -name $name | wc -l)" -gt 1  ]; do
      echo "Waiting for $name to stop"
      sleep 10
    done
  done
}


init
backup_manifest
backup_etcd_conf
backup_etcd_client_certs
stop_etcd
gen_config
download_cert_recover_template
populate_template
start_cert_recover
verify_certs
stop_cert_recover

etcd_member_add
start_etcd
