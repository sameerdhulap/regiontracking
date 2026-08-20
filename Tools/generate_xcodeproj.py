#!/usr/bin/env python3
"""
Regenerates RegionMonitor.xcodeproj from whatever is on disk under
RegionMonitor/.

Run this after adding or renaming source files if you'd rather not let Xcode
touch the pbxproj. It walks the source directory, rebuilds the group tree and
build phases, and writes a fresh project file.

    python3 Tools/generate_xcodeproj.py

IDs are derived from a hash of each object's path and role, so re-running the
script on an unchanged tree produces a byte-identical file. That keeps the
pbxproj out of your diffs unless something really moved.
"""

import hashlib
import os
import shutil
import sys

PROJECT_NAME = "RegionMonitor"
BUNDLE_ID = "com.woosmap.app.citytime"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(ROOT, PROJECT_NAME)
PROJECT_DIR = os.path.join(ROOT, f"{PROJECT_NAME}.xcodeproj")

# Order matters only for readability of the generated file.
GROUP_ORDER = ["App", "Persistence", "Location", "Export", "Views"]


def oid(*parts: str) -> str:
    """Stable 24-char hex identifier, the shape Xcode expects."""
    digest = hashlib.sha256("::".join(parts).encode("utf-8")).hexdigest()
    return digest[:24].upper()


def discover_sources():
    """Returns {group_name: [relative_path, ...]} for every .swift file."""
    groups = {}
    for dirpath, dirnames, filenames in os.walk(SOURCE_DIR):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        swift = sorted(f for f in filenames if f.endswith(".swift"))
        if not swift:
            continue
        rel_dir = os.path.relpath(dirpath, SOURCE_DIR)
        group = "." if rel_dir == "." else rel_dir.split(os.sep)[0]
        bucket = groups.setdefault(group, [])
        for name in swift:
            bucket.append(os.path.relpath(os.path.join(dirpath, name), SOURCE_DIR))
    return groups


def ordered_groups(groups):
    known = [g for g in GROUP_ORDER if g in groups]
    rest = sorted(g for g in groups if g not in GROUP_ORDER and g != ".")
    return known + rest


# --------------------------------------------------------------------------
# Build settings
# --------------------------------------------------------------------------

PROJECT_COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "SDKROOT": "iphoneos",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}

PROJECT_DEBUG = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)',
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
    "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
}

PROJECT_RELEASE = {
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
}

TARGET_COMMON = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "DEVELOPMENT_TEAM": '""',
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": f"{PROJECT_NAME}/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_VERSION": SWIFT_VERSION,
    "TARGETED_DEVICE_FAMILY": '"1,2"',
}


def settings_block(pairs, indent="\t\t\t\t"):
    lines = []
    for key in sorted(pairs):
        lines.append(f"{indent}{key} = {pairs[key]};")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# pbxproj emission
# --------------------------------------------------------------------------

def build_pbxproj(groups):
    order = ordered_groups(groups)

    project_id = oid("project", PROJECT_NAME)
    target_id = oid("target", PROJECT_NAME)
    product_id = oid("product", PROJECT_NAME)
    main_group_id = oid("group", "<root>")
    products_group_id = oid("group", "Products")
    src_group_id = oid("group", PROJECT_NAME)
    resources_group_id = oid("group", "Resources")

    sources_phase_id = oid("phase", "sources")
    frameworks_phase_id = oid("phase", "frameworks")
    resources_phase_id = oid("phase", "resources")

    project_cfg_list = oid("cfglist", "project")
    target_cfg_list = oid("cfglist", "target")

    assets_ref = oid("fileref", "Resources/Assets.xcassets")
    assets_build = oid("buildfile", "Resources/Assets.xcassets")
    plist_ref = oid("fileref", "Info.plist")

    out = []
    w = out.append

    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {")
    w("\t};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")

    # ---- PBXBuildFile -----------------------------------------------------
    w("\n/* Begin PBXBuildFile section */")
    for group in order:
        for rel in groups[group]:
            name = os.path.basename(rel)
            w(f"\t\t{oid('buildfile', rel)} /* {name} in Sources */ = "
              f"{{isa = PBXBuildFile; fileRef = {oid('fileref', rel)} /* {name} */; }};")
    w(f"\t\t{assets_build} /* Assets.xcassets in Resources */ = "
      f"{{isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }};")
    w("/* End PBXBuildFile section */")

    # ---- PBXFileReference -------------------------------------------------
    w("\n/* Begin PBXFileReference section */")
    w(f'\t\t{product_id} /* {PROJECT_NAME}.app */ = {{isa = PBXFileReference; '
      f'explicitFileType = wrapper.application; includeInIndex = 0; '
      f'path = {PROJECT_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    for group in order:
        for rel in groups[group]:
            name = os.path.basename(rel)
            w(f'\t\t{oid("fileref", rel)} /* {name} */ = {{isa = PBXFileReference; '
              f'lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
    w(f'\t\t{assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; '
      f'lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
    w(f'\t\t{plist_ref} /* Info.plist */ = {{isa = PBXFileReference; '
      f'lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    w("/* End PBXFileReference section */")

    # ---- PBXFrameworksBuildPhase -----------------------------------------
    w("\n/* Begin PBXFrameworksBuildPhase section */")
    w(f"\t\t{frameworks_phase_id} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")

    # ---- PBXGroup ---------------------------------------------------------
    w("\n/* Begin PBXGroup section */")

    w(f"\t\t{main_group_id} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{src_group_id} /* {PROJECT_NAME} */,")
    w(f"\t\t\t\t{products_group_id} /* Products */,")
    w("\t\t\t);")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    w(f"\t\t{products_group_id} /* Products */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{product_id} /* {PROJECT_NAME}.app */,")
    w("\t\t\t);")
    w("\t\t\tname = Products;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    w(f"\t\t{src_group_id} /* {PROJECT_NAME} */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for group in order:
        w(f"\t\t\t\t{oid('group', group)} /* {group} */,")
    w(f"\t\t\t\t{resources_group_id} /* Resources */,")
    w(f"\t\t\t\t{plist_ref} /* Info.plist */,")
    w("\t\t\t);")
    w(f"\t\t\tpath = {PROJECT_NAME};")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    for group in order:
        w(f"\t\t{oid('group', group)} /* {group} */ = {{")
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for rel in groups[group]:
            w(f"\t\t\t\t{oid('fileref', rel)} /* {os.path.basename(rel)} */,")
        w("\t\t\t);")
        w(f"\t\t\tpath = {group};")
        w("\t\t\tsourceTree = \"<group>\";")
        w("\t\t};")

    w(f"\t\t{resources_group_id} /* Resources */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{assets_ref} /* Assets.xcassets */,")
    w("\t\t\t);")
    w("\t\t\tpath = Resources;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    w("/* End PBXGroup section */")

    # ---- PBXNativeTarget --------------------------------------------------
    w("\n/* Begin PBXNativeTarget section */")
    w(f"\t\t{target_id} /* {PROJECT_NAME} */ = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {target_cfg_list} /* Build configuration list */;")
    w("\t\t\tbuildPhases = (")
    w(f"\t\t\t\t{sources_phase_id} /* Sources */,")
    w(f"\t\t\t\t{frameworks_phase_id} /* Frameworks */,")
    w(f"\t\t\t\t{resources_phase_id} /* Resources */,")
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t);")
    w(f"\t\t\tname = {PROJECT_NAME};")
    w(f"\t\t\tproductName = {PROJECT_NAME};")
    w(f"\t\t\tproductReference = {product_id} /* {PROJECT_NAME}.app */;")
    w("\t\t\tproductType = \"com.apple.product-type.application\";")
    w("\t\t};")
    w("/* End PBXNativeTarget section */")

    # ---- PBXProject -------------------------------------------------------
    w("\n/* Begin PBXProject section */")
    w(f"\t\t{project_id} /* Project object */ = {{")
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    w("\t\t\t\tLastUpgradeCheck = 1600;")
    w("\t\t\t\tTargetAttributes = {")
    w(f"\t\t\t\t\t{target_id} = {{")
    w("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    w("\t\t\t\t\t};")
    w("\t\t\t\t};")
    w("\t\t\t};")
    w(f"\t\t\tbuildConfigurationList = {project_cfg_list} /* Build configuration list */;")
    w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    w("\t\t\tdevelopmentRegion = en;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t);")
    w(f"\t\t\tmainGroup = {main_group_id};")
    w(f"\t\t\tproductRefGroup = {products_group_id} /* Products */;")
    w("\t\t\tprojectDirPath = \"\";")
    w("\t\t\tprojectRoot = \"\";")
    w("\t\t\ttargets = (")
    w(f"\t\t\t\t{target_id} /* {PROJECT_NAME} */,")
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")

    # ---- PBXResourcesBuildPhase ------------------------------------------
    w("\n/* Begin PBXResourcesBuildPhase section */")
    w(f"\t\t{resources_phase_id} /* Resources */ = {{")
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w(f"\t\t\t\t{assets_build} /* Assets.xcassets in Resources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")

    # ---- PBXSourcesBuildPhase --------------------------------------------
    w("\n/* Begin PBXSourcesBuildPhase section */")
    w(f"\t\t{sources_phase_id} /* Sources */ = {{")
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for group in order:
        for rel in groups[group]:
            w(f"\t\t\t\t{oid('buildfile', rel)} /* {os.path.basename(rel)} in Sources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")

    # ---- XCBuildConfiguration --------------------------------------------
    w("\n/* Begin XCBuildConfiguration section */")

    for label, extra in (("Debug", PROJECT_DEBUG), ("Release", PROJECT_RELEASE)):
        cfg_id = oid("cfg", "project", label)
        merged = dict(PROJECT_COMMON)
        merged.update(extra)
        w(f"\t\t{cfg_id} /* {label} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        w(settings_block(merged))
        w("\t\t\t};")
        w(f"\t\t\tname = {label};")
        w("\t\t};")

    for label in ("Debug", "Release"):
        cfg_id = oid("cfg", "target", label)
        w(f"\t\t{cfg_id} /* {label} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        w(settings_block(TARGET_COMMON))
        w("\t\t\t};")
        w(f"\t\t\tname = {label};")
        w("\t\t};")

    w("/* End XCBuildConfiguration section */")

    # ---- XCConfigurationList ---------------------------------------------
    w("\n/* Begin XCConfigurationList section */")
    for scope, list_id in (("project", project_cfg_list), ("target", target_cfg_list)):
        w(f"\t\t{list_id} /* Build configuration list */ = {{")
        w("\t\t\tisa = XCConfigurationList;")
        w("\t\t\tbuildConfigurations = (")
        w(f"\t\t\t\t{oid('cfg', scope, 'Debug')} /* Debug */,")
        w(f"\t\t\t\t{oid('cfg', scope, 'Release')} /* Release */,")
        w("\t\t\t);")
        w("\t\t\tdefaultConfigurationIsVisible = 0;")
        w("\t\t\tdefaultConfigurationName = Release;")
        w("\t\t};")
    w("/* End XCConfigurationList section */")

    w("\t};")
    w(f"\trootObject = {project_id} /* Project object */;")
    w("}")

    return "\n".join(out) + "\n", target_id, product_id, project_id


SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{name}.app"
               BlueprintName = "{name}"
               ReferencedContainer = "container:{name}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

WORKSPACE_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""

WORKSPACE_SETTINGS = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>IDEDidComputeMac32BitWarning</key>
	<true/>
</dict>
</plist>
"""


def main():
    if not os.path.isdir(SOURCE_DIR):
        sys.exit(f"Source directory not found: {SOURCE_DIR}")

    groups = discover_sources()
    if not groups:
        sys.exit("No .swift files found — nothing to generate.")

    pbxproj, target_id, _, _ = build_pbxproj(groups)

    if os.path.isdir(PROJECT_DIR):
        shutil.rmtree(PROJECT_DIR)

    os.makedirs(os.path.join(PROJECT_DIR, "project.xcworkspace", "xcshareddata"), exist_ok=True)
    os.makedirs(os.path.join(PROJECT_DIR, "xcshareddata", "xcschemes"), exist_ok=True)

    with open(os.path.join(PROJECT_DIR, "project.pbxproj"), "w") as f:
        f.write(pbxproj)

    with open(os.path.join(PROJECT_DIR, "project.xcworkspace", "contents.xcworkspacedata"), "w") as f:
        f.write(WORKSPACE_TEMPLATE)

    with open(os.path.join(PROJECT_DIR, "project.xcworkspace", "xcshareddata",
                           "IDEWorkspaceChecks.plist"), "w") as f:
        f.write(WORKSPACE_SETTINGS)

    scheme_path = os.path.join(PROJECT_DIR, "xcshareddata", "xcschemes", f"{PROJECT_NAME}.xcscheme")
    with open(scheme_path, "w") as f:
        f.write(SCHEME_TEMPLATE.format(target_id=target_id, name=PROJECT_NAME))

    total = sum(len(v) for v in groups.values())
    print(f"Wrote {PROJECT_NAME}.xcodeproj with {total} source files "
          f"across {len(groups)} groups.")


if __name__ == "__main__":
    main()
