#!/usr/bin/env python3
"""Generate the dependency-free native app project from the same sources as SwiftPM."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent
project = root / "Mosaic.xcodeproj"
project.mkdir(exist_ok=True)
def uid(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def q(value): return '"' + value.replace('"', '\\"') + '"'
objects = []
def obj(key, value): objects.append(f"\t\t{uid(key)} = {{ {value} }};")
source_paths = sorted(p.relative_to(root).as_posix() for p in (root / "Sources").rglob("*.swift"))
resources = ["Resources/Mosaic.icns", "Resources/Info.plist", "Resources/Mosaic.entitlements"]
for path in source_paths + resources:
    file_type = "sourcecode.swift" if path.endswith(".swift") else "image.icns" if path.endswith(".icns") else "text.plist.xml"
    obj("file:"+path, f"isa = PBXFileReference; lastKnownFileType = {file_type}; path = {q(path)}; sourceTree = SOURCE_ROOT;")
for path in source_paths + [resources[0]]:
    obj("build:"+path, f"isa = PBXBuildFile; fileRef = {uid('file:'+path)};")
obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Mosaic.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj("sources", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (" + ",".join(uid("build:"+p) for p in source_paths) + "); runOnlyForDeploymentPostprocessing = 0;")
obj("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid('build:'+resources[0])}); runOnlyForDeploymentPostprocessing = 0;")
obj("frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
for group, paths in [("Swift sources",source_paths),("Resources",resources)]:
    obj("group:"+group, "isa = PBXGroup; children = (" + ",".join(uid("file:"+p) for p in paths) + f"); name = {q(group)}; sourceTree = \"<group>\";")
obj("group:Products", f'isa = PBXGroup; children = ({uid("product")}); name = Products; sourceTree = "<group>";')
obj("mainGroup", 'isa = PBXGroup; children = (' + ",".join(uid("group:"+g) for g in ["Swift sources","Resources","Products"]) + '); sourceTree = "<group>";')
for scope in ["project", "target"]:
    for mode in ["Debug", "Release"]:
        settings = {"SDKROOT":"macosx", "MACOSX_DEPLOYMENT_TARGET":"14.0", "SWIFT_VERSION":"5.0", "CLANG_ENABLE_MODULES":"YES"}
        if scope == "target":
            settings.update({"PRODUCT_NAME":"Mosaic", "PRODUCT_BUNDLE_IDENTIFIER":"com.doctorschmoctor.Mosaic", "INFOPLIST_FILE":"Resources/Info.plist", "GENERATE_INFOPLIST_FILE":"NO", "SWIFT_INCLUDE_PATHS":"$(SRCROOT)/Sources/CSQLite", "CODE_SIGN_STYLE":"Manual", "CODE_SIGN_IDENTITY":"-", "CODE_SIGN_ENTITLEMENTS":"Resources/Mosaic.entitlements", "ENABLE_HARDENED_RUNTIME":"YES", "SWIFT_EMIT_LOC_STRINGS":"YES", "LD_RUNPATH_SEARCH_PATHS":"$(inherited) @executable_path/../Frameworks"})
        settings.update({"SWIFT_OPTIMIZATION_LEVEL":"-Onone" if mode == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT":"dwarf" if mode == "Debug" else "dwarf-with-dsym"})
        if mode == "Debug": settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        obj(scope+mode, "isa = XCBuildConfiguration; buildSettings = {" + " ".join(f"{k} = {q(v)};" for k,v in settings.items()) + f" }}; name = {mode};")
    obj(scope+"Configurations", "isa = XCConfigurationList; buildConfigurations = (" + ",".join(uid(scope+m) for m in ["Debug","Release"]) + "); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
obj("target", f"isa = PBXNativeTarget; buildConfigurationList = {uid('targetConfigurations')}; buildPhases = ({uid('sources')},{uid('frameworks')},{uid('resources')}); buildRules = (); dependencies = (); name = Mosaic; productName = Mosaic; productReference = {uid('product')}; productType = \"com.apple.product-type.application\";")
obj("project", f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1610; }}; buildConfigurationList = {uid("projectConfigurations")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {uid("mainGroup")}; productRefGroup = {uid("group:Products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")});')
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {uid('project')};\n}}\n")
scheme_dir = project / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="Mosaic.app" BlueprintName="Mosaic" ReferencedContainer="container:Mosaic.xcodeproj"/>'
(scheme_dir / "Mosaic.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1610" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated Mosaic.xcodeproj")
