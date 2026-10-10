.PHONY: build test app install clean bench
build:
	swift build
test:
	swift test
app:
	scripts/bundle.sh
install:
	scripts/bundle.sh --install
clean:
	rm -rf .build build
bench:
	scripts/bench.sh
