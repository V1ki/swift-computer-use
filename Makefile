SHELL := /bin/bash
ROOT  := $(shell pwd)

.PHONY: build test js-test app install uninstall dev clean dist

build:
	swift build --scratch-path .build-local

test:
	swift test --scratch-path .build-local

js-test:
	cd js && node --test test/

app:
	./scripts/build-app.sh

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

dev:
	./scripts/dev-service.sh

clean:
	rm -rf .build .build-* build .devhome
	rm -rf js/node_modules

dist: app
	cd build && /usr/bin/ditto -c -k --keepParent SwiftCUA.app SwiftCUA.app.zip
