# rail-runner: see README.md and docs/sandbox-socket.md.
GO ?= go
VERSION ?= $(shell git describe --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X main.version=$(VERSION)
PLATFORMS := linux/amd64 linux/arm64 darwin/arm64

.PHONY: build test clean

# dist/<os>-<arch>/rail-runner for each platform.
build:
	@set -e; for p in $(PLATFORMS); do \
		os=$${p%/*}; arch=$${p#*/}; \
		echo "dist/$$os-$$arch/rail-runner"; \
		CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o dist/$$os-$$arch/rail-runner . ; \
	done

# The CI lane: gofmt, vet, race tests.
test:
	@out=$$(gofmt -l .); if [ -n "$$out" ]; then echo "gofmt -l:"; echo "$$out"; exit 1; fi
	$(GO) vet ./...
	$(GO) test -race ./...

clean:
	rm -rf ./dist
