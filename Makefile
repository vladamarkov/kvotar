# Three targets (STEP_237, STEP_239). Build output lives outside the source tree, under
# $KVOTAR_BUILD_DIR (default ${TMPDIR:-/tmp}/kvotar-build). Nothing here signs or notarizes.

.PHONY: check test build

# The absolute rules' static tripwires and the agent-doc path check (STEP_239).
check:
	scripts/check_rules.sh

test:
	scripts/test.sh

build:
	@tmp="$${TMPDIR:-/tmp}"; BUILD="$${KVOTAR_BUILD_DIR:-$${tmp%/}/kvotar-build}"; \
	set -e; \
	xcodegen generate; \
	xcodebuild build -project Kvotar.xcodeproj -scheme Kvotar -configuration Release \
		-derivedDataPath "$$BUILD/xcode" \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO -quiet; \
	echo "Built (unsigned): $$BUILD/xcode/Build/Products/Release/Kvotar.app"
