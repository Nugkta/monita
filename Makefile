.PHONY: setup check build install test-observers

setup:
	npm ci --prefix monitor-probe/runtime --ignore-scripts --no-audit --no-fund

check:
	sh task-island/release.sh

build:
	sh task-island/build.sh

install:
	python3 task-island/update-installed.py

test-observers:
	node monitor-probe/test.mjs
