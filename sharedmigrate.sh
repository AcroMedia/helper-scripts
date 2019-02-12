#!/bin/sh

trap bail INT
function bail() {
  oc -n ${NAMESPACE} delete dc/migrator
  oc -n ${NAMESPACE} delete pvc/migrator
  oc -n ${NAMESPACE} adm policy remove-scc-from-user privileged -z migrator
  oc -n ${NAMESPACE} delete serviceaccount migrator
  exit
}

for util in oc svcat jq; do 
which ${util} > /dev/null
if [ $? -gt 0 ]; then
  echo "please install ${util}"
  exit 1
fi
done;

# n- namespace
# c- class ( lagoon-dbaas-mariadb-apb )
# p- plan ( production / stage )

args=`getopt n:c:p:i: $*` 
if [[ $# -eq 0 ]]; then
  echo "usage: $0 -n namespace -c broker-class -p broker-plan -i instance"
  echo "e.g.: $0 -n mysite-devel -c lagoon-dbaas-mariadb-apb -p development -i mariadb"
  exit
fi

# set some defaults
NAMESPACE=$(oc project -q)
PLAN=production
CLASS=lagoon-dbaas-mariadb-apb

set -- $args
for i
do
    case "$i"
        in
        -n)
            NAMESPACE="$2"; shift;
	    shift;;
        -c)
            CLASS="$2"; shift;
            shift;;
	-p)
            PLAN="$2"; shift;
            shift;;
	-i)
            INSTANCE="$2"; shift;
	    shift;;
        --)
            shift; break;;
    esac
done

# set a default instance, if not specified.
if [ -z ${INSTANCE+x} ]; then
  INSTANCE=$(svcat -n ${NAMESPACE} get instance -o json |jq -r '.items[0].metadata.name')
  echo "instance not specified, using $INSTANCE"
fi

# verify instance exists
svcat -n ${NAMESPACE} get instance $INSTANCE
if [ $? -gt 0 ] ;then 
    echo "no instance found"
    exit 2
fi


# validate $broker

oc -n ${NAMESPACE} create serviceaccount migrator
oc -n ${NAMESPACE} adm policy add-scc-to-user privileged -z migrator

oc -n ${NAMESPACE} run --image mariadb --env="MYSQL_RANDOM_ROOT_PASSWORD=yes"  migrator

# pause and make some changes
oc -n ${NAMESPACE} rollout pause deploymentconfig/migrator

# We don't care about the database in /var/lib/mysql; just privilege it and let it do its thing. 
oc -n ${NAMESPACE} patch deploymentconfig/migrator -p '{"spec":{"template":{"spec":{"serviceAccountName": "migrator"}}}}'
oc -n ${NAMESPACE} patch deploymentconfig/migrator -p '{"spec":{"template":{"spec":{"securityContext":{ "privileged": "true",  "runAsUser": 0 }}}}}'


# create a volume to store the dump.
cat << EOF | oc -n ${NAMESPACE} apply -f -
  apiVersion: v1
  items:
  - apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: migrator
    spec:
      accessModes:
      - ReadWriteOnce
      resources:
        requests:
          storage: 20Gi
  kind: List
  metadata: {}
EOF

oc -n ${NAMESPACE} volume deploymentconfig/migrator --add --name=migrator --type=persistentVolumeClaim --claim-name=migrator --mount-path=/migrator


# look up the secret from the instance and add it to the new container
SECRET=$(svcat get binding -o json  |jq -r ".items[] | select (.spec.instanceRef.name == \"$INSTANCE\") | .spec.secretName")
echo secret: $SECRET
oc -n ${NAMESPACE} set env --from=secret/${SECRET} --prefix=OLD_ dc/migrator

oc -n ${NAMESPACE} rollout resume deploymentconfig/migrator
oc -n ${NAMESPACE} rollout status deploymentconfig/migrator --watch
sleep 30;

# Do the dump: 
POD=$(oc -n ${NAMESPACE} get pods -o json --show-all=false -l run=migrator | jq -r '.items[].metadata.name')

oc -n ${NAMESPACE} exec $POD -- bash -c 'mysqldump -h $OLD_DB_HOST -u $OLD_DB_USER -p${OLD_DB_PASSWORD} $OLD_DB_NAME > /migrator/migration.sql'

echo "DUMP IS DONE;"
oc -n ${NAMESPACE} exec $POD -- head /migrator/migration.sql
oc -n ${NAMESPACE} exec $POD -- tail /migrator/migration.sql

#TODO; ask if this dump is ok.


# delete the old servicebroker
svcat deprovision $INSTANCE --wait

# set some parameters to be compatible with oc-build-deploy-dind
export OPENSHIFT_PROJECT=${NAMESPACE}
export SERVICE_NAME=${INSTANCE}
export SERVICEBROKER_CLASS=${CLASS}
export SERVICEBROKER_PLAN=${PLAN}
. $(git rev-parse --show-toplevel)/images/oc-build-deploy-dind/scripts/exec-openshift-create-servicebroker.sh

#Now lookup the new binding and add it to the migrator;

SECRET=$(svcat get binding -o json  |jq -r ".items[] | select (.spec.instanceRef.name == \"$INSTANCE\") | .spec.secretName")
echo secret: $SECRET
oc -n ${NAMESPACE} set env --from=secret/${SECRET} --prefix=NEW_ dc/migrator

oc -n ${NAMESPACE} rollout resume deploymentconfig/migrator
oc -n ${NAMESPACE} rollout status deploymentconfig/migrator --watch

# Do the dump: 
POD=$(oc -n ${NAMESPACE} get pods -o json --show-all=false -l run=migrator | jq -r '.items[].metadata.name')

oc -n ${NAMESPACE} exec $POD -- bash -c 'mysql -h $NEW_DB_HOST -u $NEW_DB_USER -p${NEW_DB_PASSWORD} $NEW_DB_NAME < /migrator/migration.sql'

bail()