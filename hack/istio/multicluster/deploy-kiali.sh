#!/bin/bash

##############################################################################
# deploy-kiali.sh
#
# Installs Kiali in both clusters.
#
##############################################################################

SCRIPT_DIR="$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)"
source ${SCRIPT_DIR}/env.sh $*

if [ "${KIALI_ENABLED}" != "true" ]; then
  echo "Will not install kiali"
  return 0
else
  if [ "${SINGLE_KIALI}" == "true" ]; then
    echo "Installing Kiali in a single cluster."
  else
    echo "Installing Kiali in the two clusters"
  fi
fi

if ! which helm; then
  echo "You do not have helm in your PATH - will not install Kiali"
  return 1
fi

deploy_kiali() {
  local helm_args=()
  if [ "${IS_OPENSHIFT}" == "true" ]; then
    helm_args="--disable-openapi-validation"
    if [ "${KIALI_USE_DEV_IMAGE}" == "true" ]; then
      echo "'--kiali-use-dev-image true' is not supported with Openshift today - will not install Kiali"
      return 1
    fi
  fi

  local cluster_name="${1}"
  local web_fqdn="${2}"
  local web_schema="${3}"
  [ -n "${web_fqdn}" ] && helm_args+=("--set server.web_fqdn=${web_fqdn}")
  [ -n "${web_schema}" ] && helm_args+=("--set server.web_schema=${web_schema}")

  # Setting this as an array so things expand correctly.
  local auth_flags=()
  if [ "${KIALI_AUTH_STRATEGY}" == "anonymous" ]; then
    auth_flags=("--set auth.strategy=anonymous")
  elif [ "${KIALI_AUTH_STRATEGY}" == "openid" ]; then
    # These need to exist prior to installing Kiali.
    # Create secret with the oidc secret
    ${CLIENT_EXE} create configmap kiali-cabundle --from-file="openid-server-ca.crt=${KEYCLOAK_CERTS_DIR}/root-ca.pem" -n "${ISTIO_NAMESPACE}"
    ${CLIENT_EXE} create secret generic kiali --from-literal="oidc-secret=kube-client-secret" -n istio-system
    ${CLIENT_EXE} create clusterrolebinding kiali-user-viewer --clusterrole=kiali-viewer --user=oidc:kiali

    auth_flags=(
      "--set auth.strategy=openid"
      "--set auth.openid.client_id=kube"
      "--set-string auth.openid.issuer_uri=https://${KEYCLOAK_ADDRESS}/realms/kube"
      "--set auth.openid.insecure_skip_verify_tls=false"
      "--set auth.openid.username_claim=preferred_username"
    )
  else
    echo "Kiali auth strategy [${KIALI_AUTH_STRATEGY}] is not supported for multi-cluster - will not install Kiali"
    return 1
  fi

  if [ "${KIALI_USE_DEV_IMAGE}" == "true" ]; then
    if [ "${MANAGE_KIND}" == "true" ]; then
      echo "Pushing the images into the cluster..."
      make -e DORP="${DORP}" -e CLUSTER_TYPE="kind" -e KIND_NAME="${cluster_name}" CLUSTER_REPO=localhost cluster-push-kiali
      helm_args+=('--set deployment.image_pull_policy="Never"')
    else
      local image_to_tag="quay.io/kiali/kiali:dev"
      local image_to_push="${minikube_ip}:5000/kiali/kiali:dev"
      echo "Tagging the dev image [${image_to_tag}] -> [${image_to_push}]..."
      ${DORP} tag ${image_to_tag} ${image_to_push}
      echo "Pushing the dev image [${image_to_push}] to the cluster [${cluster_name}]..."
      ${DORP} push --tls-verify=false ${image_to_push}
    fi
    helm_args+=("--set deployment.image_name=localhost/kiali/kiali --set deployment.image_version=dev")
  fi


  if [ "${KIALI_CREATE_REMOTE_CLUSTER_SECRETS}" == "true" ]; then
    if [ "${SINGLE_KIALI}" == "true" ]; then
      local remote_url_flag=""
      if [ "${MANAGE_KIND}" == "true" ]; then
        remote_url_flag="--remote-cluster-url https://$(${CLIENT_EXE} get nodes ${CLUSTER2_NAME}-control-plane --context ${CLUSTER2_CONTEXT} -o jsonpath='{.status.addresses[?(@.type == "InternalIP")].address}'):6443"
      fi
      echo "Preparing remote cluster secret for single Kiali install in multicluster mode."
      ${SCRIPT_DIR}/kiali-prepare-remote-cluster.sh -c ${CLIENT_EXE} --remote-cluster-name ${CLUSTER2_NAME} -kcc ${CLUSTER1_CONTEXT} -rcc ${CLUSTER2_CONTEXT} ${remote_url_flag} -vo false
    else
      echo "Preparing remote cluster secrets for both Kiali installs."
      local remote_url_flag1=""
      local remote_url_flag2=""
      if [ "${MANAGE_KIND}" == "true" ]; then
        remote_url_flag1="--remote-cluster-url https://$(${CLIENT_EXE} get nodes ${CLUSTER2_NAME}-control-plane --context ${CLUSTER2_CONTEXT} -o jsonpath='{.status.addresses[?(@.type == "InternalIP")].address}'):6443"
        remote_url_flag2="--remote-cluster-url https://$(${CLIENT_EXE} get nodes ${CLUSTER1_NAME}-control-plane --context ${CLUSTER1_CONTEXT} -o jsonpath='{.status.addresses[?(@.type == "InternalIP")].address}'):6443"
      fi
      ${SCRIPT_DIR}/kiali-prepare-remote-cluster.sh -c ${CLIENT_EXE} --remote-cluster-name ${CLUSTER2_NAME} -kcc ${CLUSTER1_CONTEXT} -rcc ${CLUSTER2_CONTEXT} ${remote_url_flag1} -vo false
      ${SCRIPT_DIR}/kiali-prepare-remote-cluster.sh -c ${CLIENT_EXE} --remote-cluster-name ${CLUSTER1_NAME} -kcc ${CLUSTER2_CONTEXT} -rcc ${CLUSTER1_CONTEXT} ${remote_url_flag2} -vo false
    fi
  fi

  local helm_auth_flags="${auth_flags[*]}"
  
  helm_command='helm upgrade --install
    ${helm_args[@]}
    --namespace ${ISTIO_NAMESPACE}
    ${helm_auth_flags}
    --set deployment.logger.log_level="debug" 
    --set deployment.service_type="LoadBalancer"
    --set external_services.grafana.url="http://grafana.istio-system:3000"
    --set external_services.grafana.dashboards[0].name="Istio Mesh Dashboard"
    --set external_services.tracing.url="http://tracing.istio-system:16685/jaeger"
    --set health_config.rate[0].kind="service"
    --set health_config.rate[0].name="y-server"
    --set health_config.rate[0].namespace="alpha"
    --set health_config.rate[0].tolerance[0].code="5xx"
    --set health_config.rate[0].tolerance[0].degraded=2
    --set health_config.rate[0].tolerance[0].failure=100
    --set deployment.ingress.enabled="false"
    --set deployment.service_type="LoadBalancer"
    --set server.web_port="80"
    --repo https://kiali.org/helm-charts
    kiali-server
    ${KIALI_SERVER_HELM_CHARTS}'

  eval $helm_command
  # Helm chart doesn't support passing in service opts so patch them after the helm deploy.
  kubectl patch service kiali -n "${ISTIO_NAMESPACE}" --type=json -p='[{"op": "replace", "path": "/spec/ports/0/port", "value":80}]'
  kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' -n istio-system service/kiali

  # If using openid auth strategy, create the keycloak realm and the kiali user.

  if [ "${KIALI_AUTH_STRATEGY}" == "openid" ]; then
    # Get a token from keycloak to use the admin api
    TOKEN_KEY=$(curl -k -X POST https://"${KEYCLOAK_ADDRESS}"/realms/master/protocol/openid-connect/token \
                -d grant_type=password \
                -d client_id=admin-cli \
                -d username=admin \
                -d password=admin \
                -d scope=openid \
                -d response_type=id_token | jq -r '.access_token')

    # Replace the redirect URI with the minikube ip. Create the realm.
    local KIALI_SVC_LB_IP=$(kubectl get svc kiali -o=jsonpath='{.status.loadBalancer.ingress[0].ip}' -n istio-system)
    jq ".clients[] |= if .clientId == \"kube\" then .redirectUris = [\"http://${KIALI_SVC_LB_IP}/kiali/*\"] else . end" < "${SCRIPT_DIR}"/realm-export-template.json | curl -k -L https://"${KEYCLOAK_ADDRESS}"/admin/realms -H "Authorization: Bearer $TOKEN_KEY" -H "Content-Type: application/json" -X POST -d @-

    # Create the kiali user
    curl -k -L https://"${KEYCLOAK_ADDRESS}"/admin/realms/kube/users -H "Authorization: Bearer $TOKEN_KEY" -d '{"username": "kiali", "enabled": true, "credentials": [{"type": "password", "value": "kiali"}]}' -H 'Content-Type: application/json'
  
    # Create a clusterrolebinding so that the kiali oidc user can view and edit resources in kiali.
    kubectl apply --context "${CLUSTER1_CONTEXT}" -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kiali-testing-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kiali
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: oidc:kiali
EOF

    # Copy the kiali-viewer cluster role to the west cluster
    kubectl get clusterrole kiali -o yaml --context "${CLUSTER1_CONTEXT}" | kubectl apply --context "${CLUSTER2_CONTEXT}" -f -
    
    # Create a clusterrolebinding in the west cluster so that the kiali oidc user can view resources in kiali.
    kubectl apply --context "${CLUSTER2_CONTEXT}" -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kiali-testing-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kiali
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: oidc:kiali
EOF
  fi
}


echo "==== DEPLOY KIALI TO CLUSTER #1 [${CLUSTER1_NAME}] - ${CLUSTER1_CONTEXT} (keycloak is at ${CLUSTER1_NAME})"
switch_cluster "${CLUSTER1_CONTEXT}" "${CLUSTER1_USER}" "${CLUSTER1_PASS}"
deploy_kiali "${CLUSTER1_NAME}" "${KIALI1_WEB_FQDN}" "${KIALI1_WEB_SCHEMA}"

if [ "${SINGLE_KIALI}" != "true" ]
then
  echo "==== DEPLOY KIALI TO CLUSTER #2 [${CLUSTER2_NAME}] - ${CLUSTER2_CONTEXT} (keycloak is at ${CLUSTER1_NAME})"
  switch_cluster "${CLUSTER2_CONTEXT}" "${CLUSTER2_USER}" "${CLUSTER2_PASS}"
  deploy_kiali "${CLUSTER2_NAME}" "${KIALI2_WEB_FQDN}" "${KIALI2_WEB_SCHEMA}"
fi
