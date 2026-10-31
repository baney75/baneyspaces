.PHONY: build test app install release clean bench brand shots
build:
	swift build
test:
	swift test
app:
	scripts/bundle.sh
install:
	scripts/bundle.sh --install
# On the owner's Mac, after pushing the tag: signs the app, packages it and uploads it to the release.
release:
	scripts/release.sh
clean:
	rm -rf .build build
bench:
	scripts/bench.sh
# The README banner and the GitHub social card, drawn from the icon.
brand:
	swift scripts/make-icon.swift build/BaneySpaces.iconset
	swift scripts/make-brand.swift build/BaneySpaces.iconset/icon_512x512@2x.png docs
# Product images with sample windows (never your real ones), refreshed into docs/shots.
shots: build
	rm -rf build/shots
	.build/debug/BaneySpaces --render build/shots
	sips -s format jpeg -s formatOptions 90 build/shots/overview.png --out docs/shots/overview.jpg >/dev/null
	sips -s format jpeg -s formatOptions 90 build/shots/overview-drag.png --out docs/shots/overview-drag.jpg >/dev/null
	sips -s format jpeg -s formatOptions 90 build/shots/setup-first-run.png --out docs/shots/setup.jpg >/dev/null
	cp build/shots/deck.png build/shots/deck-toast.png docs/shots/
