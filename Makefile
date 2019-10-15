SERVICE_IMAGE := docker.io/usercont/packit-service
WORKER_IMAGE := docker.io/usercont/packit-service-worker
WORKER_PROD_IMAGE := docker.io/usercont/packit-service-worker:prod
TEST_IMAGE := packit-service-tests
TEST_TARGET := ./tests/unit ./tests/integration/
CONTAINER_ENGINE := podman

build: files/install-deps.yaml files/recipe.yaml
	docker build --rm -t $(SERVICE_IMAGE) .

worker: CONTAINER_ENGINE ?= docker
worker: files/install-deps-worker.yaml files/recipe-worker.yaml
	$(CONTAINER_ENGINE) build --rm -t $(WORKER_IMAGE) -f Dockerfile.worker .

# this is for cases when you want to deploy into production and don't want to wait for dockerhub
worker-prod: files/install-deps-worker.yaml files/recipe-worker.yaml
	docker build --rm -t $(WORKER_PROD_IMAGE) -f Dockerfile.worker.prod .
worker-prod-push: worker-prod
	docker push $(WORKER_PROD_IMAGE)

# we can't use rootless podman here b/c we can't mount ~/.ssh inside (0400)
run-worker:
	docker run -it --rm --net=host \
		-u 1000 \
		-e FLASK_ENV=development \
		-e PAGURE_USER_TOKEN \
		-e PAGURE_FORK_TOKEN \
		-e GITHUB_TOKEN \
		-w /src \
		-v ~/.ssh/:/home/packit/.ssh/:Z \
		-v $(CURDIR):/src:Z \
		$(WORKER_IMAGE) bash

run-fedmsg:
	docker run -it --rm --net=host \
		-u 1000 \
		-w /src \
		-v ~/.ssh/:/home/packit/.ssh/:Z \
		-v $(CURDIR):/src:Z \
		$(WORKER_IMAGE) bash

check:
	find . -name "*.pyc" -exec rm {} \;
	PYTHONPATH=$(CURDIR) PYTHONDONTWRITEBYTECODE=1 python3 -m pytest --color=yes --verbose --showlocals --cov=packit_service --cov-report=term-missing $(TEST_TARGET)

test_image: CONTAINER_ENGINE ?= podman
test_image: files/install-deps.yaml files/recipe-tests.yaml
	$(CONTAINER_ENGINE) build --rm -t $(TEST_IMAGE) -f Dockerfile.tests .

check_in_container: test_image
	$(CONTAINER_ENGINE) run --rm -ti \
		-v $(CURDIR):/src-packit-service \
		-w /src-packit-service \
		--security-opt label=disable \
		-v $(CURDIR)/files/packit-service.yaml:/root/.config/packit-service.yaml \
		$(TEST_IMAGE) make check

# deploy a pod with tests and run them
check-inside-openshift: CONTAINER_ENGINE=docker
check-inside-openshift: test_image
	oc delete job packit-tests || :
	@# http://timmurphy.org/2015/09/27/how-to-get-a-makefile-directory-path/
	@# sadly the hostPath volume doesn't work:
	@#   Invalid value: "hostPath": hostPath volumes are not allowed to be used
	@#   username system:admin is invalid for basic auth
	@#-p PACKIT_SERVICE_SRC_LOCAL_PATH=$(dir $(realpath $(firstword $(MAKEFILE_LIST))))
	oc process -f files/test-in-openshift.yaml | oc create -f -
	oc wait job/packit-tests --for condition=complete --timeout=60s
	oc logs job/packit-tests
	# this garbage tells us if the tests passed or not
	oc get job packit-tests -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' | grep True

# this target is expected to run within an openshift pod
check-within-openshift:
	/src-packit-service/files/setup_env_in_openshift.sh
	pytest-3 -k test_update
