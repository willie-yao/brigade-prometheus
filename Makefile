SHELL ?= /bin/bash

.DEFAULT_GOAL := build

################################################################################
# Version details                                                              #
################################################################################

# This will reliably return the short SHA1 of HEAD or, if the working directory
# is dirty, will return that + "-dirty"
GIT_VERSION = $(shell git describe --always --abbrev=7 --dirty --match=NeVeRmAtCh)

################################################################################
# Containerized development environment-- or lack thereof                      #
################################################################################

ifneq ($(SKIP_DOCKER),true)
	PROJECT_ROOT := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))
	GO_DEV_IMAGE := brigadecore/go-tools:v0.1.0

	GO_DOCKER_CMD := docker run \
		-it \
		--rm \
		-e SKIP_DOCKER=true \
		-e GITHUB_TOKEN=$${GITHUB_TOKEN} \
		-e GOCACHE=/workspaces/brigade-prometheus/.gocache \
		-v $(PROJECT_ROOT):/workspaces/brigade-prometheus \
		-w /workspaces/brigade-prometheus \
		$(GO_DEV_IMAGE)

	KANIKO_IMAGE := brigadecore/kaniko:v0.2.0

	KANIKO_DOCKER_CMD := docker run \
		-it \
		--rm \
		-e SKIP_DOCKER=true \
		-e DOCKER_PASSWORD=$${DOCKER_PASSWORD} \
		-v $(PROJECT_ROOT):/workspaces/brigade-prometheus \
		-w /workspaces/brigade-prometheus \
		$(KANIKO_IMAGE)

	HELM_IMAGE := brigadecore/helm-tools:v0.1.0

	HELM_DOCKER_CMD := docker run \
	  -it \
		--rm \
		-e SKIP_DOCKER=true \
		-e HELM_PASSWORD=$${HELM_PASSWORD} \
		-v $(PROJECT_ROOT):/workspaces/brigade-prometheus \
		-w /workspaces/brigade-prometheus \
		$(HELM_IMAGE)
endif

################################################################################
# Binaries and Docker images we build and publish                              #
################################################################################

ifdef DOCKER_REGISTRY
	DOCKER_REGISTRY := $(DOCKER_REGISTRY)/
endif

ifdef DOCKER_ORG
	DOCKER_ORG := $(DOCKER_ORG)/
endif

DOCKER_IMAGE_PREFIX := $(DOCKER_REGISTRY)$(DOCKER_ORG)brigade-prometheus-

ifdef HELM_REGISTRY
	HELM_REGISTRY := $(HELM_REGISTRY)/
endif

ifdef HELM_ORG
	HELM_ORG := $(HELM_ORG)/
endif

HELM_CHART_PREFIX := $(HELM_REGISTRY)$(HELM_ORG)

ifdef VERSION
	MUTABLE_DOCKER_TAG := latest
else
	VERSION            := $(GIT_VERSION)
	MUTABLE_DOCKER_TAG := edge
endif

IMMUTABLE_DOCKER_TAG := $(VERSION)

################################################################################
# Tests                                                                        #
################################################################################

.PHONY: lint
lint:
	$(GO_DOCKER_CMD) sh -c ' \
		cd v2/exporter && \
		golangci-lint run --config ../../golangci.yaml \
	'

.PHONY: test-unit
test-unit:
	$(GO_DOCKER_CMD) sh -c ' \
		cd v2/exporter && \
		go test \
			-v \
			-timeout=60s \
			-race \
			-coverprofile=coverage.txt \
			-covermode=atomic \
			./... \
	'

################################################################################
# Build                                                                        #
################################################################################

.PHONY: build
build: build-images

.PHONY: build-images
build-images: build-exporter build-prometheus build-grafana

.PHONY: build-%
build-%:
	$(KANIKO_DOCKER_CMD) kaniko \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(GIT_VERSION) \
		--dockerfile /workspaces/brigade-prometheus/v2/$*/Dockerfile \
		--context dir:///workspaces/brigade-prometheus/ \
		--no-push

################################################################################
# Publish                                                                      #
################################################################################

.PHONY: publish
publish: push-images publish-chart

.PHONY: push-images
push-images: push-images push-prometheus push-grafana

.PHONY: push-%
push-%:
	$(KANIKO_DOCKER_CMD) sh -c ' \
		docker login $(DOCKER_REGISTRY) -u $(DOCKER_USERNAME) -p $${DOCKER_PASSWORD} && \
		kaniko \
			--build-arg VERSION="$(VERSION)" \
			--build-arg COMMIT="$(GIT_VERSION)" \
			--dockerfile /workspaces/brigade-prometheus/v2/$*/Dockerfile \
			--context dir:///workspaces/brigade-prometheus/ \
			--destination $(DOCKER_IMAGE_PREFIX)$*:$(IMMUTABLE_DOCKER_TAG) \
			--destination $(DOCKER_IMAGE_PREFIX)$*:$(MUTABLE_DOCKER_TAG) \
	'

.PHONY: publish-chart
publish-chart:
	$(HELM_DOCKER_CMD) sh	-c ' \
		helm registry login $(HELM_REGISTRY) -u $(HELM_USERNAME) -p $${HELM_PASSWORD} && \
		cd charts/brigade-prometheus && \
		helm dep up && \
		sed -i "s/^version:.*/version: $(VERSION)/" Chart.yaml && \
		sed -i "s/^appVersion:.*/appVersion: $(VERSION)/" Chart.yaml && \
		helm chart save . $(HELM_CHART_PREFIX)brigade-prometheus:$(VERSION) && \
		helm chart push $(HELM_CHART_PREFIX)brigade-prometheus:$(VERSION) \
	'

################################################################################
# Targets to facilitate hacking on Brigade Prometheus.                         #
################################################################################

.PHONY: hack-new-kind-cluster
hack-new-kind-cluster:
	hack/kind/new-cluster.sh

.PHONY: hack-build-images
hack-build-images: hack-build-exporter hack-build-prometheus hack-build-grafana

.PHONY: hack-build-%
hack-build-%:
	docker build \
		-f v2/$*/Dockerfile \
		-t $(DOCKER_IMAGE_PREFIX)$*:$(IMMUTABLE_DOCKER_TAG) \
		--build-arg VERSION='$(VERSION)' \
		--build-arg COMMIT='$(GIT_VERSION)' \
		.

.PHONY: hack-push-images
hack-push-images: hack-push-exporter hack-push-prometheus hack-push-grafana

.PHONY: hack-push-%
hack-push-%: hack-build-%
	docker push $(DOCKER_IMAGE_PREFIX)$*:$(IMMUTABLE_DOCKER_TAG)

IMAGE_PULL_POLICY ?= Always

.PHONY: hack-deploy
hack-deploy:
	helm dep up charts/brigade-prometheus && \
	helm upgrade brigade-prometheus charts/brigade-prometheus \
		--install \
		--create-namespace \
		--namespace brigade-prometheus \
		--wait \
		--timeout 600s \
		--set exporter.image.repository=$(DOCKER_IMAGE_PREFIX)prometheus \
		--set exporter.image.tag=$(IMMUTABLE_DOCKER_TAG) \
		--set exporter.image.pullPolicy=$(IMAGE_PULL_POLICY) \
		--set prometheus.image.repository=$(DOCKER_IMAGE_PREFIX)prometheus \
		--set prometheus.image.tag=$(IMMUTABLE_DOCKER_TAG) \
		--set prometheus.image.pullPolicy=$(IMAGE_PULL_POLICY) \
		--set grafana.image.repository=$(DOCKER_IMAGE_PREFIX)prometheus \
		--set grafana.image.tag=$(IMMUTABLE_DOCKER_TAG) \
		--set grafana.image.pullPolicy=$(IMAGE_PULL_POLICY)

.PHONY: hack
hack: hack-push-images hack-deploy

# Convenience targets for loading images into a KinD cluster
.PHONY: hack-load-images
hack-load-images: load-exporter load-prometheus load-grafana

load-%:
	@echo "Loading $(DOCKER_IMAGE_PREFIX)$*:$(IMMUTABLE_DOCKER_TAG)"
	@kind load docker-image $(DOCKER_IMAGE_PREFIX)$*:$(IMMUTABLE_DOCKER_TAG) \
			|| echo >&2 "kind not installed or error loading image: $(DOCKER_IMAGE_PREFIX)$*:$(IMMUTABLE_DOCKER_TAG)"
