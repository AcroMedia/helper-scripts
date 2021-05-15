#!/bin/bash

set -eu -o pipefail

#
# Migrate Namespace between two Kubernetes Clusters, this is tested for ASK where it's easily possible to mount persistent storage from two clusters in the same region
# this might not work for EKS or GKE.
#
# Prework needed for this to work
# - add vnet of destination cluster to databases access (or the destination namespace will not be able to talk to the DataBases)
#

usage() {
  echo "Usage: ./migrate-between-clusters.sh -n drupal-example2-test9-master -s amazeeio-test9 -d amazeeio-test10"
  echo "Options:"
  echo "  -n <NAMESPACE>              #required, which namespace should be migrated"
  echo "  -s <SOURCE_CONTEXT>         #required, source context - needs to be a context in your kubeconfig"
  echo "  -d <DESTINATION_CONTEXT>    #required, destination context - needs to be a context in your kubeconfig"
  echo "  -z skip                     #optional, should the scaledown of source deployments be skipped, by default enabled"
  exit 1
}

if [[ ! $@ =~ ^\-.+ ]]
then
  usage
fi

SKIP_SOURCE_SCALEDOWN=false

while getopts ":n:s:d:z::" opt; do
  case ${opt} in
    n ) # process option n
      NAMESPACE=$OPTARG;;
    s ) # process option s
      SOURCE=$OPTARG;;
    d ) # process option d
      DESTINATION=$OPTARG;;
    z ) # process option z
      SKIP_SOURCE_SCALEDOWN=$OPTARG;;
    h )
      usage;;
    *)
      usage;;
  esac
done

if [[ -z "$NAMESPACE" || -z "$SOURCE" || -z "$DESTINATION" ]]; then
  usage
fi

set -v

# Export all objectes
# Important: child objects like Pods are not exported as they are created again when the Parent object is created
echo "configmaps persistentvolumeclaims secrets services deployments.apps statefulsets horizontalpodautoscalers poddisruptionbudgets cronjobs.batch certificates.cert-manager.io  mariadbconsumers.mariadb.amazee.io mongodbconsumers.mongodb.amazee.io postgresqlconsumers.postgres.amazee.io rolebindings.rbac.authorization.k8s.io roles.rbac.authorization.k8s.io" | xargs -n 1 \
  kubectl --context="$SOURCE" get -n "$NAMESPACE" -o json > "$NAMESPACE-original.json"

# Export Ingress, we need them separately later
kubectl --context="$SOURCE" get -n "$NAMESPACE" ingresses -o json > "$NAMESPACE-original-ingress.json"

SOURCE_NAMESPACE_PVS=$(kubectl --context="$SOURCE" get pv -o=json | jq ".items[]|select(.spec.claimRef.namespace==\"$NAMESPACE\")|.metadata.name" -r)
if [[ ! -z "$SOURCE_NAMESPACE_PVS" ]]; then
  # Patch PVs to "persistentVolumeReclaimPolicy: Retain" or they could be deleted during the migration
  kubectl --context="$SOURCE" patch pv ${SOURCE_NAMESPACE_PVS} -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
  # Export all PVs that are used by the given Namespace
  kubectl --context="$SOURCE" get pv ${SOURCE_NAMESPACE_PVS} -o json > "$NAMESPACE-original-pv.json"
fi

# export the Namespace itself, this keeps namespace labels
kubectl --context="$SOURCE" get ns "$NAMESPACE" -o json > "$NAMESPACE-original-ns.json"

if [ "${SKIP_SOURCE_SCALEDOWN}" != "skip" ]; then
  # Scale down all deployments in source namespace, this ensures ReadWriteOnce (RWO) PVs can be mounted by the destination namespace
  kubectl --context="$SOURCE" -n "$NAMESPACE" scale  deployment --all --replicas=0
fi

# Create target Namespace
kubectl --context="$DESTINATION" create -f "$NAMESPACE-original-ns.json"

# Create the lagoon-deploy ServiceAccount, we create this manually in order for k8s to create new tokens
kubectl --context="$DESTINATION" -n "$NAMESPACE" create sa lagoon-deployer

# Import our objects
kubectl --context="$DESTINATION" -n "$NAMESPACE" create -f "$NAMESPACE-original.json"
if [[ ! -z "$SOURCE_NAMESPACE_PVS" ]]; then
  kubectl --context="$DESTINATION" -n "$NAMESPACE" create -f "$NAMESPACE-original-pv.json"
fi

# Create regular Ingresses, skip autogenerated ingresses, lagoon will create them again
if [[ ! -z $(cat "$NAMESPACE-original-ingress.json" | jq '.items[]|select(.metadata.labels."lagoon.sh/autogenerated"!="true")' --raw-output) ]]; then
  cat "$NAMESPACE-original-ingress.json" | jq '.items[]|select(.metadata.labels."lagoon.sh/autogenerated"!="true")' --raw-output | kubectl --context="$DESTINATION" -n "$NAMESPACE" create -f -
fi

DESTINATION_NAMESPACE_PVS=$(kubectl --context="$DESTINATION" get pv -o=json | jq ".items[]|select(.spec.claimRef.namespace==\"$NAMESPACE\")|.metadata.name" -r)
if [[ ! -z "$DESTINATION_NAMESPACE_PVS" ]]; then
  # Remove the claimref from the PVs as the UID of the PVC have changed, the PVCs are already pointing to the PVs and therefore will be bound immediatelly again
  kubectl --context="$DESTINATION" patch pv ${DESTINATION_NAMESPACE_PVS} --type json -p '[{"op": "remove", "path": "/spec/claimRef"}]'
fi

# Remove the metadata/annotations/kubectl.kubernetes.io/last-applied-configuration annotation of lagoon managed objects, as they could cuase an error the next time we lagoon deploy
LAGOON_MANAGED_RESOURCES=$(kubectl --context="$DESTINATION" -n "$NAMESPACE" -l lagoon.sh/project get service,deployment,secret,ingress,configmap,cronjobs,mariadbconsumers,mongodbconsumers,postgresqlconsumers,horizontalpodautoscalers,poddisruptionbudgets,pvc -o name)
if [[ ! -z "$LAGOON_MANAGED_RESOURCES" ]]; then
  kubectl --context="$DESTINATION" -n "$NAMESPACE" patch $LAGOON_MANAGED_RESOURCES --type json -p '[{"op": "remove", "path": "/metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration"}]'
fi