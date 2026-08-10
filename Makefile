.PHONY: build test app dmg run clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh release

dmg:
	./scripts/build-dmg.sh

run: app
	open "dist/Dynamic Island.app"

clean:
	swift package clean
	rm -rf dist
