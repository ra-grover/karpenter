export K8S_VERSION ?= 1.23.x
export KUBEBUILDER_ASSETS ?= ${HOME}/.kubebuilder/bin
CLUSTER_NAME ?= $(shell kubectl config view --minify -o jsonpath='{.clusters[].name}' | rev | cut -d"/" -f1 | rev | cut -d"." -f1)

## Inject the app version into project.Version
ifdef SNAPSHOT_TAG
LDFLAGS ?= -ldflags=-X=github.com/aws/karpenter/pkg/utils/project.Version=$(SNAPSHOT_TAG)
else
LDFLAGS ?= -ldflags=-X=github.com/aws/karpenter/pkg/utils/project.Version=$(shell git describe --tags --always)
endif

GOFLAGS ?= $(LDFLAGS)
WITH_GOFLAGS = GOFLAGS="$(GOFLAGS)"

## Extra helm options
CLUSTER_ENDPOINT ?= $(shell kubectl config view --minify -o jsonpath='{.clusters[].cluster.server}')
AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text)
KARPENTER_IAM_ROLE_ARN ?= arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter
HELM_OPTS ?= --set serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${KARPENTER_IAM_ROLE_ARN} \
      		--set settings.aws.clusterName=${CLUSTER_NAME} \
			--set settings.aws.clusterEndpoint=${CLUSTER_ENDPOINT} \
			--set settings.aws.defaultInstanceProfile=KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
			--set settings.aws.enableInterruptionHandling=true \
			--create-namespace

# CR for local builds of Karpenter
SYSTEM_NAMESPACE ?= karpenter
KARPENTER_VERSION ?= $(shell git tag --sort=committerdate | tail -1)
KO_DOCKER_REPO ?= ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/karpenter
GETTING_STARTED_SCRIPT_DIR = website/content/en/preview/getting-started/getting-started-with-eksctl/scripts

# Common Directories
MOD_DIRS = $(shell find . -name go.mod -type f | xargs dirname)
KARPENTER_CORE_DIR = $(shell go list -m -f '{{ .Dir }}' github.com/aws/karpenter-core)

help: ## Display help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

presubmit: verify test ## Run all steps in the developer loop

ci-test: battletest coverage ## Runs tests and submits coverage

ci-non-test: verify licenses vulncheck ## Runs checks other than tests

ci: toolchain ci-non-tests ci-tests ## Run all steps used by continuous integration

run: ## Run Karpenter controller binary against your local cluster
	SYSTEM_NAMESPACE=${SYSTEM_NAMESPACE} go run ./cmd/controller/main.go \
		--cluster-name=${CLUSTER_NAME} \
		--cluster-endpoint=${CLUSTER_ENDPOINT} \
		--aws-default-instance-profile=KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
		--leader-elect=false

test: ## Run tests
	go test -v ./pkg/... --ginkgo.focus="${FOCUS}"

battletest: ## Run randomized, racing, code coveraged, tests
	go test -v ./pkg/... \
		-race \
		-cover -coverprofile=coverage.out -outputdir=. -coverpkg=./pkg/... \
		--ginkgo.focus="${FOCUS}" \
		--ginkgo.randomize-all \
		-tags random_test_delay

e2etests: ## Run the e2e suite against your local cluster
	cd test && CLUSTER_NAME=${CLUSTER_NAME} go test -p 1 -count 1 -timeout 180m -v ./suites/... --ginkgo.focus="${FOCUS}"

benchmark:
	go test -tags=test_performance -run=NoTests -bench=. ./...

deflake:
	for i in $(shell seq 1 5); do make battletest || exit 1; done

coverage:
	go tool cover -html coverage.out -o coverage.html

verify: tidy download ## Verify code. Includes dependencies, linting, formatting, etc
	go generate ./...
	hack/boilerplate.sh
	curl https://raw.githubusercontent.com/aws/karpenter-core/v0.0.1/chart/crds/karpenter.sh_provisioners.yaml > pkg/apis/crds/karpenter.sh_provisioners.yaml
	$(foreach dir,$(MOD_DIRS),cd $(dir) && golangci-lint run $(newline))
	@git diff --quiet ||\
		{ echo "New file modification detected in the Git working tree. Please check in before commit."; git --no-pager diff --name-only | uniq | awk '{print "  - " $$0}'; \
		if [ $(MAKECMDGOALS) = 'ci-non-test' ]; then\
			exit 1;\
		fi;}
	@echo "Validating codegen/docgen build scripts..."
	@find hack/code hack/docs -name "*.go" -type f -exec go build -o /dev/null {} \;

vulncheck: ## Verify code vulnerabilities
	@govulncheck ./pkg/...

licenses: download ## Verifies dependency licenses
	! go-licenses csv ./... | grep -v -e 'MIT' -e 'Apache-2.0' -e 'BSD-3-Clause' -e 'BSD-2-Clause' -e 'ISC' -e 'MPL-2.0'

setup: ## Sets up the IAM roles needed prior to deploying the karpenter-controller. This command only needs to be run once
	CLUSTER_NAME=${CLUSTER_NAME} ./$(GETTING_STARTED_SCRIPT_DIR)/add-roles.sh $(KARPENTER_VERSION)

build: ## Build the Karpenter controller images using ko build
	$(eval CONTROLLER_IMG=$(shell $(WITH_GOFLAGS) ko build -B github.com/aws/karpenter/cmd/controller))

apply: build ## Deploy the controller from the current state of your git repository into your ~/.kube/config cluster
	helm upgrade --install karpenter charts/karpenter --namespace ${SYSTEM_NAMESPACE} \
		$(HELM_OPTS) \
		--set controller.image=$(CONTROLLER_IMG)

install:  ## Deploy the latest released version into your ~/.kube/config cluster
	@echo Upgrading to $(shell grep version charts/karpenter/Chart.yaml)
	helm upgrade --install karpenter charts/karpenter --namespace ${SYSTEM_NAMESPACE} \
		$(HELM_OPTS)

delete: ## Delete the controller from your ~/.kube/config cluster
	helm uninstall karpenter --namespace karpenter

docgen: ## Generate docs
	go run hack/docs/metrics_gen_docs.go pkg/ $(KARPENTER_CORE_DIR)/pkg website/content/en/preview/tasks/metrics.md
	go run hack/docs/instancetypes_gen_docs.go website/content/en/preview/AWS/instance-types.md
	go run hack/docs/configuration_gen_docs.go website/content/en/preview/tasks/globalsettings.md

api-code-gen: ## Auto generate files based on AWS APIs response
	$(WITH_GOFLAGS) ./hack/api-code-gen.sh

stable-release-pr: ## Generate PR for stable release
	$(WITH_GOFLAGS) ./hack/release/stable-pr.sh

nightly: ## Tag the latest snapshot release with timestamp
	./hack/release/add-snapshot-tag.sh $(shell git rev-parse HEAD) $(shell date +"%Y%m%d") "nightly"

release: ## Builds and publishes stable release if env var RELEASE_VERSION is set, or a snapshot release otherwise
	$(WITH_GOFLAGS) ./hack/release/release.sh

prepare-website: ## prepare the website for release
	./hack/release/prepare-website.sh

toolchain: ## Install developer toolchain
	./hack/toolchain.sh

issues: ## Run GitHub issue analysis scripts
	pip install -r ./hack/github/requirements.txt
	@echo "Set GH_TOKEN env variable to avoid being rate limited by Github"
	./hack/github/feature_request_reactions.py > "karpenter-feature-requests-$(shell date +"%Y-%m-%d").csv"
	./hack/github/label_issue_count.py > "karpenter-labels-$(shell date +"%Y-%m-%d").csv"

website: ## Serve the docs website locally
	cd website && npm install && git submodule update --init --recursive && hugo server

tidy: ## Recursively "go mod tidy" on all directories where go.mod exists
	$(foreach dir,$(MOD_DIRS),cd $(dir) && go mod tidy $(newline))

download: ## Recursively "go mod download" on all directories where go.mod exists
	$(foreach dir,$(MOD_DIRS),cd $(dir) && go mod download $(newline))

.PHONY: help dev ci release test battletest e2etests verify tidy download docgen apply delete toolchain licenses vulncheck issues website nightly snapshot

define newline


endef
