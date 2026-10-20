default: build

build:
  bash scripts/package-app.sh

test:
  bash scripts/test.sh

format:
  xcrun swift-format format --in-place --recursive Package.swift Sources Tests

lint:
  xcrun swift-format lint --strict --recursive Package.swift Sources Tests
  shellcheck scripts/*.sh
  swift build -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror

run: build
  open .build/PRDEBar.app
