.PHONY: setup gen build clean open

setup:
	brew install xcodegen
	$(MAKE) gen

gen:
	xcodegen generate

build: gen
	xcodebuild -project Lector.xcodeproj -scheme Lector -configuration Debug build

clean:
	rm -rf Lector.xcodeproj
	xcodebuild -project Lector.xcodeproj -scheme Lector clean 2>/dev/null || true

open: gen
	open Lector.xcodeproj
