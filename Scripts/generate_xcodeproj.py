#!/usr/bin/env python3
"""Generate GPSTracker.xcodeproj from the sources under GPSTracker/.

Run from the repository root:  python3 Scripts/generate_xcodeproj.py
Re-run after adding or removing source files.
"""
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "GPSTracker"
BUNDLE_ID = "com.gpstracker.app"
PROJ_DIR = os.path.join(ROOT, APP + ".xcodeproj")

_counter = [0]


def uid():
    _counter[0] += 1
    return "AA%022X" % _counter[0]


class Node:
    def __init__(self, name, path, is_dir):
        self.name = name
        self.path = path            # path relative to its parent group
        self.is_dir = is_dir
        self.children = []
        self.uid = uid()


def scan(abs_dir, rel_name):
    node = Node(rel_name, rel_name, True)
    for entry in sorted(os.listdir(abs_dir)):
        if entry.startswith('.'):
            continue
        full = os.path.join(abs_dir, entry)
        if os.path.isdir(full):
            if entry.endswith('.xcassets'):
                node.children.append(Node(entry, entry, False))
            else:
                node.children.append(scan(full, entry))
        else:
            node.children.append(Node(entry, entry, False))
    return node


def file_type(name):
    if name.endswith('.swift'):
        return 'sourcecode.swift'
    if name.endswith('.xcassets'):
        return 'folder.assetcatalog'
    if name.endswith('.plist'):
        return 'text.plist.xml'
    if name.endswith('.entitlements'):
        return 'text.plist.entitlements'
    if name.endswith('.md'):
        return 'net.daringfireball.markdown'
    if name.endswith('.json'):
        return 'text.json'
    return 'text'


def collect(node, out_sources, out_resources):
    for child in node.children:
        if child.is_dir:
            collect(child, out_sources, out_resources)
        elif child.name.endswith('.swift'):
            out_sources.append(child)
        elif child.name.endswith('.xcassets'):
            out_resources.append(child)


def main():
    root_node = scan(os.path.join(ROOT, APP), APP)
    sources, resources = [], []
    collect(root_node, sources, resources)

    build_files = {}   # file node uid -> build file uid
    for f in sources + resources:
        build_files[f.uid] = uid()

    product_uid = uid()
    products_group_uid = uid()
    main_group_uid = uid()
    target_uid = uid()
    project_uid = uid()
    sources_phase = uid()
    frameworks_phase = uid()
    resources_phase = uid()
    proj_cfg_list = uid()
    target_cfg_list = uid()
    proj_debug, proj_release = uid(), uid()
    tgt_debug, tgt_release = uid(), uid()

    L = []
    w = L.append
    w('// !$*UTF8*$!')
    w('{')
    w('\tarchiveVersion = 1;')
    w('\tclasses = {')
    w('\t};')
    w('\tobjectVersion = 56;')
    w('\tobjects = {')
    w('')

    w('/* Begin PBXBuildFile section */')
    for f in sources:
        w('\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
          % (build_files[f.uid], f.name, f.uid, f.name))
    for f in resources:
        w('\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
          % (build_files[f.uid], f.name, f.uid, f.name))
    w('/* End PBXBuildFile section */')
    w('')

    w('/* Begin PBXFileReference section */')
    w('\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; '
      'includeInIndex = 0; path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; };' % (product_uid, APP, APP))

    def emit_refs(node):
        for child in node.children:
            if child.is_dir:
                emit_refs(child)
            else:
                w('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; '
                  'sourceTree = "<group>"; };' % (child.uid, child.name, file_type(child.name), child.name))
    emit_refs(root_node)
    w('/* End PBXFileReference section */')
    w('')

    w('/* Begin PBXFrameworksBuildPhase section */')
    w('\t\t%s /* Frameworks */ = {' % frameworks_phase)
    w('\t\t\tisa = PBXFrameworksBuildPhase;')
    w('\t\t\tbuildActionMask = 2147483647;')
    w('\t\t\tfiles = (')
    w('\t\t\t);')
    w('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    w('\t\t};')
    w('/* End PBXFrameworksBuildPhase section */')
    w('')

    w('/* Begin PBXGroup section */')
    w('\t\t%s = {' % main_group_uid)
    w('\t\t\tisa = PBXGroup;')
    w('\t\t\tchildren = (')
    w('\t\t\t\t%s /* %s */,' % (root_node.uid, APP))
    w('\t\t\t\t%s /* Products */,' % products_group_uid)
    w('\t\t\t);')
    w('\t\t\tsourceTree = "<group>";')
    w('\t\t};')
    w('\t\t%s /* Products */ = {' % products_group_uid)
    w('\t\t\tisa = PBXGroup;')
    w('\t\t\tchildren = (')
    w('\t\t\t\t%s /* %s.app */,' % (product_uid, APP))
    w('\t\t\t);')
    w('\t\t\tname = Products;')
    w('\t\t\tsourceTree = "<group>";')
    w('\t\t};')

    def emit_groups(node):
        w('\t\t%s /* %s */ = {' % (node.uid, node.name))
        w('\t\t\tisa = PBXGroup;')
        w('\t\t\tchildren = (')
        for child in node.children:
            w('\t\t\t\t%s /* %s */,' % (child.uid, child.name))
        w('\t\t\t);')
        w('\t\t\tpath = %s;' % node.path)
        w('\t\t\tsourceTree = "<group>";')
        w('\t\t};')
        for child in node.children:
            if child.is_dir:
                emit_groups(child)
    emit_groups(root_node)
    w('/* End PBXGroup section */')
    w('')

    w('/* Begin PBXNativeTarget section */')
    w('\t\t%s /* %s */ = {' % (target_uid, APP))
    w('\t\t\tisa = PBXNativeTarget;')
    w('\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget "%s" */;'
      % (target_cfg_list, APP))
    w('\t\t\tbuildPhases = (')
    w('\t\t\t\t%s /* Sources */,' % sources_phase)
    w('\t\t\t\t%s /* Frameworks */,' % frameworks_phase)
    w('\t\t\t\t%s /* Resources */,' % resources_phase)
    w('\t\t\t);')
    w('\t\t\tbuildRules = (')
    w('\t\t\t);')
    w('\t\t\tdependencies = (')
    w('\t\t\t);')
    w('\t\t\tname = %s;' % APP)
    w('\t\t\tproductName = %s;' % APP)
    w('\t\t\tproductReference = %s /* %s.app */;' % (product_uid, APP))
    w('\t\t\tproductType = "com.apple.product-type.application";')
    w('\t\t};')
    w('/* End PBXNativeTarget section */')
    w('')

    w('/* Begin PBXProject section */')
    w('\t\t%s /* Project object */ = {' % project_uid)
    w('\t\t\tisa = PBXProject;')
    w('\t\t\tattributes = {')
    w('\t\t\t\tBuildIndependentTargetsInParallel = 1;')
    w('\t\t\t\tLastSwiftUpdateCheck = 1500;')
    w('\t\t\t\tLastUpgradeCheck = 1500;')
    w('\t\t\t\tTargetAttributes = {')
    w('\t\t\t\t\t%s = {' % target_uid)
    w('\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;')
    w('\t\t\t\t\t};')
    w('\t\t\t\t};')
    w('\t\t\t};')
    w('\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject "%s" */;'
      % (proj_cfg_list, APP))
    w('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    w('\t\t\tdevelopmentRegion = en;')
    w('\t\t\thasScannedForEncodings = 0;')
    w('\t\t\tknownRegions = (')
    w('\t\t\t\ten,')
    w('\t\t\t\tBase,')
    w('\t\t\t);')
    w('\t\t\tmainGroup = %s;' % main_group_uid)
    w('\t\t\tproductRefGroup = %s /* Products */;' % products_group_uid)
    w('\t\t\tprojectDirPath = "";')
    w('\t\t\tprojectRoot = "";')
    w('\t\t\ttargets = (')
    w('\t\t\t\t%s /* %s */,' % (target_uid, APP))
    w('\t\t\t);')
    w('\t\t};')
    w('/* End PBXProject section */')
    w('')

    w('/* Begin PBXResourcesBuildPhase section */')
    w('\t\t%s /* Resources */ = {' % resources_phase)
    w('\t\t\tisa = PBXResourcesBuildPhase;')
    w('\t\t\tbuildActionMask = 2147483647;')
    w('\t\t\tfiles = (')
    for f in resources:
        w('\t\t\t\t%s /* %s in Resources */,' % (build_files[f.uid], f.name))
    w('\t\t\t);')
    w('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    w('\t\t};')
    w('/* End PBXResourcesBuildPhase section */')
    w('')

    w('/* Begin PBXSourcesBuildPhase section */')
    w('\t\t%s /* Sources */ = {' % sources_phase)
    w('\t\t\tisa = PBXSourcesBuildPhase;')
    w('\t\t\tbuildActionMask = 2147483647;')
    w('\t\t\tfiles = (')
    for f in sources:
        w('\t\t\t\t%s /* %s in Sources */,' % (build_files[f.uid], f.name))
    w('\t\t\t);')
    w('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    w('\t\t};')
    w('/* End PBXSourcesBuildPhase section */')
    w('')

    common = [
        ('ALWAYS_SEARCH_USER_PATHS', 'NO'),
        ('CLANG_ANALYZER_NONNULL', 'YES'),
        ('CLANG_ENABLE_MODULES', 'YES'),
        ('CLANG_ENABLE_OBJC_ARC', 'YES'),
        ('COPY_PHASE_STRIP', 'NO'),
        ('ENABLE_STRICT_OBJC_MSGSEND', 'YES'),
        ('GCC_C_LANGUAGE_STANDARD', 'gnu17'),
        ('IPHONEOS_DEPLOYMENT_TARGET', '17.0'),
        ('MTL_FAST_MATH', 'YES'),
        ('SDKROOT', 'iphoneos'),
        ('SWIFT_VERSION', '5.0'),
    ]
    debug_only = [
        ('DEBUG_INFORMATION_FORMAT', 'dwarf'),
        ('ENABLE_TESTABILITY', 'YES'),
        ('GCC_OPTIMIZATION_LEVEL', '0'),
        ('MTL_ENABLE_DEBUG_INFO', 'INCLUDE_SOURCE'),
        ('ONLY_ACTIVE_ARCH', 'YES'),
        ('SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'DEBUG'),
        ('SWIFT_OPTIMIZATION_LEVEL', '"-Onone"'),
    ]
    release_only = [
        ('DEBUG_INFORMATION_FORMAT', '"dwarf-with-dsym"'),
        ('ENABLE_NS_ASSERTIONS', 'NO'),
        ('MTL_ENABLE_DEBUG_INFO', 'NO'),
        ('SWIFT_COMPILATION_MODE', 'wholemodule'),
        ('SWIFT_OPTIMIZATION_LEVEL', '"-O"'),
        ('VALIDATE_PRODUCT', 'YES'),
    ]
    target_common = [
        ('ASSETCATALOG_COMPILER_APPICON_NAME', 'AppIcon'),
        ('ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME', 'AccentColor'),
        ('CODE_SIGN_IDENTITY', '""'),
        ('CODE_SIGN_STYLE', 'Manual'),
        ('CODE_SIGNING_ALLOWED', 'NO'),
        ('CODE_SIGNING_REQUIRED', 'NO'),
        ('CURRENT_PROJECT_VERSION', '1'),
        ('DEVELOPMENT_TEAM', '""'),
        ('ENABLE_PREVIEWS', 'YES'),
        ('GENERATE_INFOPLIST_FILE', 'NO'),
        ('INFOPLIST_FILE', '%s/Resources/Info.plist' % APP),
        ('LD_RUNPATH_SEARCH_PATHS', '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)'),
        ('MARKETING_VERSION', '1.0'),
        ('PRODUCT_BUNDLE_IDENTIFIER', BUNDLE_ID),
        ('PRODUCT_NAME', '"$(TARGET_NAME)"'),
        ('PROVISIONING_PROFILE_SPECIFIER', '""'),
        ('SWIFT_EMIT_LOC_STRINGS', 'YES'),
        ('TARGETED_DEVICE_FAMILY', '"1,2"'),
    ]

    def emit_cfg(cfg_uid, name, settings):
        w('\t\t%s /* %s */ = {' % (cfg_uid, name))
        w('\t\t\tisa = XCBuildConfiguration;')
        w('\t\t\tbuildSettings = {')
        for k, v in settings:
            w('\t\t\t\t%s = %s;' % (k, v))
        w('\t\t\t};')
        w('\t\t\tname = %s;' % name)
        w('\t\t};')

    w('/* Begin XCBuildConfiguration section */')
    emit_cfg(proj_debug, 'Debug', common + debug_only)
    emit_cfg(proj_release, 'Release', common + release_only)
    emit_cfg(tgt_debug, 'Debug', target_common)
    emit_cfg(tgt_release, 'Release', target_common)
    w('/* End XCBuildConfiguration section */')
    w('')

    w('/* Begin XCConfigurationList section */')
    for cfg_list, kind, dbg, rel in ((proj_cfg_list, 'PBXProject "%s"' % APP, proj_debug, proj_release),
                                     (target_cfg_list, 'PBXNativeTarget "%s"' % APP, tgt_debug, tgt_release)):
        w('\t\t%s /* Build configuration list for %s */ = {' % (cfg_list, kind))
        w('\t\t\tisa = XCConfigurationList;')
        w('\t\t\tbuildConfigurations = (')
        w('\t\t\t\t%s /* Debug */,' % dbg)
        w('\t\t\t\t%s /* Release */,' % rel)
        w('\t\t\t);')
        w('\t\t\tdefaultConfigurationIsVisible = 0;')
        w('\t\t\tdefaultConfigurationName = Release;')
        w('\t\t};')
    w('/* End XCConfigurationList section */')
    w('\t};')
    w('\trootObject = %s /* Project object */;' % project_uid)
    w('}')

    if os.path.isdir(PROJ_DIR):
        shutil.rmtree(PROJ_DIR)
    os.makedirs(os.path.join(PROJ_DIR, 'xcshareddata', 'xcschemes'))
    with open(os.path.join(PROJ_DIR, 'project.pbxproj'), 'w') as fh:
        fh.write('\n'.join(L) + '\n')

    scheme = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
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
               BlueprintIdentifier = "{target}"
               BuildableName = "{app}.app"
               BlueprintName = "{app}"
               ReferencedContainer = "container:{app}.xcodeproj">
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
            BlueprintIdentifier = "{target}"
            BuildableName = "{app}.app"
            BlueprintName = "{app}"
            ReferencedContainer = "container:{app}.xcodeproj">
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
            BlueprintIdentifier = "{target}"
            BuildableName = "{app}.app"
            BlueprintName = "{app}"
            ReferencedContainer = "container:{app}.xcodeproj">
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
""".replace('{target}', target_uid).replace('{app}', APP)
    with open(os.path.join(PROJ_DIR, 'xcshareddata', 'xcschemes', APP + '.xcscheme'), 'w') as fh:
        fh.write(scheme)

    print("Generated %s with %d source files and %d resources."
          % (PROJ_DIR, len(sources), len(resources)))


if __name__ == '__main__':
    main()
