.PHONY: app run install test probe clean

app:
	scripts/build-app.sh

run: app
	open "build/Dead Air.app"

install: app
	rm -rf "/Applications/Dead Air.app"
	cp -R "build/Dead Air.app" /Applications/
	open "/Applications/Dead Air.app"

test:
	swift test

probe:
	swift run DeadAir --probe 10

clean:
	rm -rf .build build
