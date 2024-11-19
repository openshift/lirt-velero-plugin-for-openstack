# Copyright 2019, 2020 the Velero contributors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# The binary to build (just the basename).
BIN ?= velero-plugin-for-openstack

# This repo's root import path (under GOPATH).
PKG := github.com/Lirt/velero-plugin-for-openstack

# Where to push the docker image.
REGISTRY ?= velero
GCR_REGISTRY ?= gcr.io/velero-gcp

# Image name
IMAGE?= $(REGISTRY)/$(BIN)
GCR_IMAGE ?= $(GCR_REGISTRY)/$(BIN)

# We allow the Dockerfile to be configurable to enable the use of custom Dockerfiles
# that pull base images from different registries.
VELERO_DOCKERFILE ?= Dockerfile.ubi

# Which architecture to build - see $(ALL_ARCH) for options.
# if the 'local' rule is being run, detect the ARCH from 'go env'
# if it wasn't specified by the caller.
local : ARCH ?= $(shell go env GOOS)-$(shell go env GOARCH)
ARCH ?= linux-amd64

VERSION ?= main

TAG_LATEST ?= false

ifeq ($(TAG_LATEST), true)
	IMAGE_TAGS ?= $(IMAGE):$(VERSION) $(IMAGE):latest
	GCR_IMAGE_TAGS ?= $(GCR_IMAGE):$(VERSION) $(GCR_IMAGE):latest
else
	IMAGE_TAGS ?= $(IMAGE):$(VERSION)
	GCR_IMAGE_TAGS ?= $(GCR_IMAGE):$(VERSION)
endif

ifeq ($(shell docker buildx inspect 2>/dev/null | awk '/Status/ { print $$2 }'), running)
	BUILDX_ENABLED ?= true
else
	BUILDX_ENABLED ?= false
endif

define BUILDX_ERROR
buildx not enabled, refusing to run this recipe
see: https://velero.io/docs/main/build-from-source/#making-images-and-updating-velero for more info
endef

CLI_PLATFORMS ?= linux-amd64 linux-arm linux-arm64 darwin-amd64 darwin-arm64 windows-amd64 linux-ppc64le
BUILDX_PLATFORMS ?= $(subst -,/,$(ARCH))
BUILDX_OUTPUT_TYPE ?= docker

# set git sha and tree state
GIT_SHA = $(shell git rev-parse HEAD)
ifneq ($(shell git status --porcelain 2> /dev/null),)
	GIT_TREE_STATE ?= dirty
else
	GIT_TREE_STATE ?= clean
endif

###
### These variables should not need tweaking.
###

platform_temp = $(subst -, ,$(ARCH))
GOOS = $(word 1, $(platform_temp))
GOARCH = $(word 2, $(platform_temp))
GOPROXY ?= https://proxy.golang.org

.PHONY: local
local: build-dirs
	GOOS=$(GOOS) \
	GOARCH=$(GOARCH) \
	VERSION=$(VERSION) \
	REGISTRY=$(REGISTRY) \
	PKG=$(PKG) \
	BIN=$(BIN) \
	GIT_SHA=$(GIT_SHA) \
	GIT_TREE_STATE=$(GIT_TREE_STATE) \
	OUTPUT_DIR=$$(pwd)/_output/bin/$(GOOS)/$(GOARCH) \
	./hack/build.sh

.PHONY: container
container:
ifneq ($(BUILDX_ENABLED), true)
	$(error $(BUILDX_ERROR))
endif
	@docker buildx build --pull \
	--output=type=$(BUILDX_OUTPUT_TYPE) \
	--platform $(BUILDX_PLATFORMS) \
	$(addprefix -t , $(IMAGE_TAGS)) \
	$(addprefix -t , $(GCR_IMAGE_TAGS)) \
	--build-arg=GOPROXY=$(GOPROXY) \
	--build-arg=PKG=$(PKG) \
	--build-arg=BIN=$(BIN) \
	--build-arg=VERSION=$(VERSION) \
	--build-arg=GIT_SHA=$(GIT_SHA) \
	--build-arg=GIT_TREE_STATE=$(GIT_TREE_STATE) \
	--build-arg=REGISTRY=$(REGISTRY) \
	-f $(VELERO_DOCKERFILE) .
	@echo "container: $(IMAGE):$(VERSION)"

# test runs unit tests using 'go test' in the local environment.
.PHONY: test
test:
	CGO_ENABLED=0 go test -v -coverprofile=coverage.out -timeout 60s ./...

.PHONY: ci
ci: verify-modules test

build-dirs:
	@mkdir -p _output/bin/$(GOOS)/$(GOARCH)
	@mkdir -p .go/src/$(PKG) .go/pkg .go/bin .go/std/$(GOOS)/$(GOARCH) .go/go-build

.PHONY: modules
modules:
	go mod tidy

.PHONY: verify-modules
verify-modules: modules
	@if !(git diff --quiet HEAD -- go.sum go.mod); then \
		echo "go module files are out of date, please commit the changes to go.mod and go.sum"; exit 1; \
	fi

changelog:
	hack/release-tools/changelog.sh

clean:
	@echo "cleaning"
	rm -rf .go _output
