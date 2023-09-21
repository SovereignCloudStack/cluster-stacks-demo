# Copyright 2023 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec
.DEFAULT_GOAL:=help

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

#############
# Variables #
#############

TIMEOUT := $(shell command -v timeout || command -v gtimeout)

# Directories
BIN_DIR := bin
TOOLS_DIR := hack/tools
TOOLS_BIN_DIR := $(TOOLS_DIR)/$(BIN_DIR)
export PATH := $(abspath $(TOOLS_BIN_DIR)):$(PATH)
export GOBIN := $(abspath $(TOOLS_BIN_DIR))

export PROVIDER=docker

# Versions
export K8S_VERSION=1-27
export CAPI_VERSION=v1.5.1
export CAPD_VERSION=v1.5.1
# Names
export NAMESPACE=scs-cs
export CLUSTER_CLASS_NAME=ferrol
export CLUSTER_NAME=cs-cluster
export CLUSTER_TOPOLOGY=true

##@ Binaries
############
# Binaries #
############

KUSTOMIZE := $(abspath $(TOOLS_BIN_DIR)/kustomize)
kustomize: $(KUSTOMIZE) ## Build a local copy of kustomize
$(KUSTOMIZE): # Build kustomize from tools folder.
	go install sigs.k8s.io/kustomize/kustomize/v5@v5.1.0

ENVSUBST := $(abspath $(TOOLS_BIN_DIR)/envsubst)
envsubst: $(ENVSUBST) ## Build a local copy of envsubst
$(ENVSUBST): # Build envsubst from tools folder.
	go install github.com/drone/envsubst/v2/cmd/envsubst@latest

CTLPTL := $(abspath $(TOOLS_BIN_DIR)/ctlptl)
ctlptl: $(CTLPTL) ## Build a local copy of ctlptl
$(CTLPTL):
	go install github.com/tilt-dev/ctlptl/cmd/ctlptl@v0.8.20

CLUSTERCTL := $(abspath $(TOOLS_BIN_DIR)/clusterctl)
clusterctl: $(CLUSTERCTL) ## Build a local copy of clusterctl
$(CLUSTERCTL):
	curl -sSLf https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.5.1/clusterctl-$$(go env GOOS)-$$(go env GOARCH) -o $(CLUSTERCTL)
	chmod a+rx $(CLUSTERCTL)

KUBECTL := $(abspath $(TOOLS_BIN_DIR)/kubectl)
kubectl: $(KUBECTL) ## Build a local copy of kubectl
$(KUBECTL):
	curl -fsSL "https://dl.k8s.io/release/v1.27.3/bin/$$(go env GOOS)/$$(go env GOARCH)/kubectl" -o $(KUBECTL)
	chmod a+rx $(KUBECTL)

HELM := $(abspath $(TOOLS_BIN_DIR)/helm)
helm: $(HELM) ## Build a local copy of helm
$(HELM):
	go install helm.sh/helm/v3/cmd/helm@v3.12.3

KIND := $(abspath $(TOOLS_BIN_DIR)/kind)
kind: $(KIND) ## Build a local copy of kind
$(KIND):
	go install sigs.k8s.io/kind@v0.20.0

all-tools: $(KIND) $(CTLPTL) $(KIND) $(ENVSUBST) $(KUSTOMIZE) $(CLUSTERCTL) $(HELM)
	echo 'done'

.PHONY: basics
basics: $(KIND) $(CTLPTL) $(KIND) $(ENVSUBST) $(KUSTOMIZE) $(CLUSTERCTL)
	@./hack/ensure-env-variables.sh CAPI_VERSION CAPD_VERSION NAMESPACE \
	    CLUSTER_CLASS_NAME K8S_VERSION CLUSTER_NAME PROVIDER
	@mkdir -p build

##@ Development
###############
# Development #
###############

.PHONY: cluster
kind-cluster: basics $(KUBECTL) ## Creates kind-dev Cluster
	./hack/kind-dev.sh
	$(KUBECTL) config set-context --current --namespace $(NAMESPACE)

.PHONY: watch
watch: $(KUBECTL) ## Show the current state of the CRDs and events.
	watch -c "$(KUBECTL) -n $(NAMESPACE) get cluster; echo; $(KUBECTL) -n $(NAMESPACE) get machine; echo; $(KUBECTL) -n $(NAMESPACE) get dockermachine; echo; echo Events; $(KUBECTL) -A get events --sort-by=metadata.creationTimestamp | tail -5"

##@ Clean
#########
# Clean #
#########
.PHONY: clean
clean: basics ## Remove all generated files
	$(MAKE) clean-bin

.PHONY: clean-bin
clean-bin: ## Remove all generated helper binaries
	rm -rf $(TOOLS_BIN_DIR)

##@ Main Targets
################
# Main Targets #
################
.PHONY: delete-bootstrap-cluster
delete-bootstrap-cluster: basics ## Deletes Kind-dev Cluster
	$(CTLPTL) delete cluster kind-scs-cluster-stacks

.PHONY: create-bootstrap-cluster
create-bootstrap-cluster: basics kind-cluster $(KUBECTL) ## Create mgt-cluster and install capi-stack.
	EXP_RUNTIME_SDK=true CLUSTER_TOPOLOGY=true DISABLE_VERSIONCHECK="true" $(CLUSTERCTL) init --core cluster-api:$(CAPI_VERSION) --bootstrap kubeadm:$(CAPI_VERSION) --control-plane kubeadm:$(CAPI_VERSION) --infrastructure docker:$(CAPD_VERSION)
	$(KUBECTL) wait -n cert-manager deployment cert-manager --for=condition=Available --timeout=300s
	$(KUBECTL) wait -n capi-kubeadm-bootstrap-system deployment capi-kubeadm-bootstrap-controller-manager --for=condition=Available --timeout=300s
	$(KUBECTL) wait -n capi-kubeadm-control-plane-system deployment capi-kubeadm-control-plane-controller-manager --for=condition=Available --timeout=300s
	$(KUBECTL) wait -n capi-system deployment capi-controller-manager --for=condition=Available --timeout=300s
	$(KUBECTL) wait -n capd-system deployment capd-controller-manager --for=condition=Available --timeout=300s
	$(KUBECTL) apply -f cso-infrastructure-components.yaml
	$(KUBECTL) wait -n cso-system deployment cso-controller-manager --for=condition=Available --timeout=300s
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f clusterstack.yaml

.PHONY: create-workload-cluster
create-workload-cluster: basics $(KUBECTL) ## Creates a workload cluster.
		$(KUBECTL) apply -f cluster.yaml
	# Wait for the kubeconfig to become available.
	${TIMEOUT} --foreground 5m bash -c "while ! $(KUBECTL) -n $(NAMESPACE) get secrets | grep $(CLUSTER_NAME)-kubeconfig; do date; echo waiting for secret $(CLUSTER_NAME)-kubeconfig; sleep 1; done"
	# Get kubeconfig and store it locally.
	@mkdir -p .kubeconfigs
	$(KUBECTL) -n $(NAMESPACE) get secrets $(CLUSTER_NAME)-kubeconfig -o json | jq -r .data.value | base64 --decode > .kubeconfigs/.$(CLUSTER_NAME)-kubeconfig
	if [ ! -s ".kubeconfigs/.$(CLUSTER_NAME)-kubeconfig" ]; then echo "failed to create .kubeconfigs/.$(CLUSTER_NAME)-kubeconfig"; exit 1; fi
	${TIMEOUT} --foreground 15m bash -c "while ! $(KUBECTL) --kubeconfig=.kubeconfigs/.$(CLUSTER_NAME)-kubeconfig -n $(NAMESPACE) get nodes | \
	   grep control-plane; do echo 'Waiting for control-plane in workload-cluster'; sleep 1; done"
	chmod a=,u=rw .kubeconfigs/.$(CLUSTER_NAME)-kubeconfig
	@echo ""
	@echo 'Access to workload API server successful.'
	@echo 'use KUBECONFIG=.kubeconfigs/.$(CLUSTER_NAME)-kubeconfig to access the workload cluster'
	KUBECONFIG=.kubeconfigs/.$(CLUSTER_NAME)-kubeconfig $(KUBECTL) apply -f kindnet.yaml
