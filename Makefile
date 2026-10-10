.PHONY: test build app

test:
	swift test

build:
	swift build -c release

app: build
	./Scripts/package-app.sh
