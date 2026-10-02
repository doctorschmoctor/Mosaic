#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swiftc -swift-version 5 -I Sources/CSQLite Sources/MosaicCore/*.swift Sources/Mosaic/WorkspaceStore.swift Sources/Mosaic/WorkspaceView.swift Sources/Mosaic/ConversationTile.swift Sources/Mosaic/ComposerEditor.swift Sources/Mosaic/SetupView.swift Sources/Mosaic/MessagesBridge.swift scripts/preview/main.swift -o .build/MosaicPreview
.build/MosaicPreview "${1:-docs/workspace.png}" --demo "${@:2}"
