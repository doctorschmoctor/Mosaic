#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swiftc -swift-version 5 -I Sources/CSQLite Sources/MosaicCore/*.swift Sources/Mosaic/WorkspaceStore.swift Sources/Mosaic/WorkspaceView.swift Sources/Mosaic/ConversationTile.swift Sources/Mosaic/ComposerEditor.swift Sources/Mosaic/Controls.swift Sources/Mosaic/SetupView.swift Sources/Mosaic/MessagesBridge.swift Sources/Mosaic/MediaViews.swift Sources/Mosaic/Scrollers.swift Sources/Mosaic/TileHeaderHandle.swift Sources/Mosaic/FocusChipBar.swift Sources/Mosaic/ComposeViews.swift Sources/Mosaic/SidebarKeyboard.swift Sources/Mosaic/Attachments.swift Sources/Mosaic/PhotoLibraryPicker.swift Sources/Mosaic/MessageTransport.swift Sources/Mosaic/ThreadDecorations.swift Sources/Mosaic/QuickLook.swift Sources/Mosaic/StoreServices.swift Sources/Mosaic/ComposerFocus.swift Sources/Mosaic/ConversationDetails.swift Sources/Mosaic/SettingsView.swift scripts/preview/main.swift -o .build/MosaicPreview
.build/MosaicPreview "${1:-docs/workspace.png}" --demo "${@:2}"
