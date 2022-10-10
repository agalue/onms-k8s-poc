#!/bin/bash
# @author Alejandro Galue <agalue@opennms.com>
#
# WARNING: For testing purposes only

set -e

for cmd in "kubectl" "helm" "keytool"; do
  type $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but it's not installed; aborting."; exit 1; }
done

NAMESPACE="shared"
TARGET_DIR="jks" # Expected location for the JKS Truststores
PG_USER="postgres" # Must match dependencies.postgresql.username from the Helm deployment
PG_PASSWORD="P0stgr3s" # Must match dependencies.postgresql.password from the Helm deployment
PG_ONMS_USER="opennms" # Must match dependencies.opennms.configuration.database.username from the Helm deployment
PG_ONMS_PASSWORD="0p3nNM5" # Must match dependencies.opennms.configuration.database.password from the Helm deployment
KAFKA_USER="opennms" # Must match dependencies.kafka.username from the Helm deployment
KAFKA_PASSWORD="0p3nNM5" # Must match dependencies.kafka.password from the Helm deployment
ELASTIC_USER="elastic" # Must match dependencies.elasticsearch.username from the Helm deployment
ELASTIC_PASSWORD="31@st1c" # Must match dependencies.elasticsearch.password from the Helm deployment
TRUSTSTORE_PASSWORD="0p3nNM5" # Must match dependencies.kafka.truststore.password from the Helm deployment
CLUSTER_NAME="onms" # Must match the name of the cluster inside dependencies/kafka.yaml and dependencies/elasticsearch.yaml

# Patch NGinx to allow SSL Passthrough for Strimzi
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type json -p \
  '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-ssl-passthrough"}]'

# Update Helm Repositories
helm repo add jetstack https://charts.jetstack.io
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Install Cert-Manager
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --set installCRDs=true --wait
kubectl apply -f ca -n cert-manager

# Create a namespace for most of the dependencies except for cert-manager (above), and the postgres and elastic operators (added below).
kubectl create namespace $NAMESPACE

# Install Grafana Loki
helm upgrade --install loki --namespace=$NAMESPACE \
  --set "fullnameOverride=loki" \
  --set "gateway.enabled=false" \
  --set "loki.storage.type=filesystem" \
  --set "monitoring.selfMonitoring.enabled=false" \
  --set "monitoring.selfMonitoring.grafanaAgent.installOperator=false" \
  --set "persistence.enabled=true" \
  --set "persistence.accessModes={ReadWriteOnce}" \
  --set "persistence.size=50Gi" \
  grafana/loki

# Install PostgreSQL
kubectl apply -f https://raw.githubusercontent.com/zalando/postgres-operator/master/manifests/postgresql.crd.yaml
kubectl apply -k github.com/zalando/postgres-operator/manifests
kubectl create secret generic $PG_USER.onms-db.credentials.postgresql.acid.zalan.do --from-literal="username=$PG_USER" --from-literal="password=$PG_PASSWORD" -n $NAMESPACE
kubectl create secret generic $PG_ONMS_USER.onms-db.credentials.postgresql.acid.zalan.do --from-literal="username=$PG_ONMS_USER" --from-literal="password=$PG_ONMS_PASSWORD" -n $NAMESPACE
kubectl apply -f dependencies/postgresql.yaml -n $NAMESPACE

# Install Kafka via Strimzi
kubectl create secret generic kafka-user-credentials --from-literal="$KAFKA_USER=$KAFKA_PASSWORD" -n $NAMESPACE
kubectl apply -f "https://strimzi.io/install/latest?namespace=$NAMESPACE" -n $NAMESPACE
kubectl apply -f dependencies/kafka.yaml -n $NAMESPACE

# Install Elasticsearch via ECK
kubectl create secret generic $CLUSTER_NAME-es-elastic-user --from-literal="$ELASTIC_USER=$ELASTIC_PASSWORD" -n $NAMESPACE
kubectl create -f https://download.elastic.co/downloads/eck/1.8.0/crds.yaml
kubectl apply -f https://download.elastic.co/downloads/eck/1.8.0/operator.yaml
kubectl apply -f dependencies/elasticsearch.yaml -n $NAMESPACE

# Wait for the clusters
kubectl wait kafka/$CLUSTER_NAME --for=condition=Ready --timeout=300s -n $NAMESPACE
kubectl wait pod -l elasticsearch.k8s.elastic.co/cluster-name=$CLUSTER_NAME --for=condition=Ready --timeout=300s -n $NAMESPACE

# Prepare target directory for the Truststores
mkdir -p $TARGET_DIR
TRUSTSTORE_TEMP="/tmp/ca.truststore.$(date +%s)"

# Add OpenNMS CA (used for PostgreSQL) to the Truststore
CERT_FILE_PATH="$TARGET_DIR/postgresql-ca.crt"
kubectl get secret onms-ca -n cert-manager -o go-template='{{index .data "ca.crt" | base64decode }}' > $CERT_FILE_PATH
keytool -import -trustcacerts -alias postgresql-ca -file $CERT_FILE_PATH -keystore $TRUSTSTORE_TEMP -storepass "$TRUSTSTORE_PASSWORD" -noprompt

# Add Elasticsearch CA to the Truststore
CERT_FILE_PATH="$TARGET_DIR/elasticsearch-ca.crt"
kubectl get secret $CLUSTER_NAME-es-http-certs-internal -n $NAMESPACE -o go-template='{{index .data "ca.crt" | base64decode }}' > $CERT_FILE_PATH
keytool -import -trustcacerts -alias elasticsearch-ca -file $CERT_FILE_PATH -keystore $TRUSTSTORE_TEMP -storepass "$TRUSTSTORE_PASSWORD" -noprompt

# Add Kafka CA to the Truststore
CERT_FILE_PATH="$TARGET_DIR/kafka-ca.crt"
kubectl get secret $CLUSTER_NAME-cluster-ca-cert -n $NAMESPACE -o go-template='{{index .data "ca.crt" | base64decode }}' > $CERT_FILE_PATH
keytool -import -trustcacerts -alias kafka-ca -file $CERT_FILE_PATH -keystore $TRUSTSTORE_TEMP -storepass "$TRUSTSTORE_PASSWORD" -noprompt

# Move Truststore to the target location
mv -f $TRUSTSTORE_TEMP $TARGET_DIR/truststore.jks

# Show all resources
kubectl get all -n $NAMESPACE

echo "Done!"
