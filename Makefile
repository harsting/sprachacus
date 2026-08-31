.PHONY: setup run bundle install setup-signing clean

# Einrichtung in einem Befehl (Voraussetzungen, Signatur, Build, Installation).
setup:
	./scripts/setup.sh

# Build, bundle and launch the app (always launch the .app via `open`,
# never the bare binary — TCC would attribute permissions to the terminal).
run: bundle
	open "build/Sprachacus.app"

bundle:
	./scripts/bundle.sh

# One-time: create the stable code-signing identity (keeps TCC grants across rebuilds).
setup-signing:
	./scripts/setup-signing.sh

# Copy the app to /Applications and launch it from there.
install: bundle
	@pkill -x Sprachacus 2>/dev/null || true
	@pkill -x DIYSpokenly 2>/dev/null || true
	rm -rf "/Applications/Sprachacus.app" "/Applications/DIY Spokenly.app"
	cp -R "build/Sprachacus.app" "/Applications/Sprachacus.app"
	open "/Applications/Sprachacus.app"

clean:
	rm -rf .build build
