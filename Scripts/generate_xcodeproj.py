#!/usr/bin/env python3
"""Generate GPSTracker.xcodeproj from the sources on disk.

Run from the repository root:  python3 Scripts/generate_xcodeproj.py
Re-run after adding or removing source files.

Targets:
  GPSTracker         — the iOS app
  GPSTrackerWidgets  — WidgetKit extension (home screen widget + Live Activity)
"""
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "GPSTracker"
WIDGET = "GPSTrackerWidgets"
BUNDLE_ID = "com.gpstracker.app"
WIDGET_BUNDLE_ID = BUNDLE_ID + ".widgets"
PROJ_DIR = os.path.join(ROOT, APP + ".xcodeproj")

# App sources that must also compile into the widget extension.
SHARED_WITH_WIDGET = ["WorkoutActivityAttributes.swift"]

_counter = [0]


def uid():
    _counter[0] += 1
    return "AA%022X" % _counter[0]


class Node:
    def __init__(self, name, path, is_dir):
        self.name = name
        self.path = path
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
    app_root = scan(os.path.join(ROOT, APP), APP)
    app_sources, app_resources = [], []
    collect(app_root, app_sources, app_resources)

    has_widget = os.path.isdir(os.path.join(ROOT, WIDGET))
    widget_root = None
    widget_sources, widget_resources = [], []
    if has_widget:
        widget_root = scan(os.path.join(ROOT, WIDGET), WIDGET)
        collect(widget_root, widget_sources, widget_resources)
        # shared files compile into both targets
        for name in SHARED_WITH_WIDGET:
            for node in app_sources:
                if node.name == name:
                    widget_sources.append(node)

    # build files are per target, so key on (target tag, file uid)
    build_files = {}

    def build_file(tag, node):
        key = (tag, node.uid)
        if key not in build_files:
            build_files[key] = uid()
        return build_files[key]

    for node in app_sources + app_resources:
        build_file('app', node)
    for node in widget_sources + widget_resources:
        build_file('widget', node)

    app_product = uid()
    widget_product = uid()
    products_group = uid()
    main_group = uid()
    app_target = uid()
    widget_target = uid()
    project_uid = uid()
    app_sources_phase = uid()
    app_frameworks_phase = uid()
    app_resources_phase = uid()
    app_embed_phase = uid()
    widget_sources_phase = uid()
    widget_frameworks_phase = uid()
    widget_resources_phase = uid()
    widget_embed_build_file = uid()
    widget_dependency = uid()
    widget_proxy = uid()
    proj_cfg_list = uid()
    app_cfg_list = uid()
    widget_cfg_list = uid()
    proj_debug, proj_release = uid(), uid()
    app_debug, app_release = uid(), uid()
    widget_debug, widget_release = uid(), uid()

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
    for node in app_sources:
        w('\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
          % (build_file('app', node), node.name, node.uid, node.name))
    for node in app_resources:
        w('\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
          % (build_file('app', node), node.name, node.uid, node.name))
    if has_widget:
        for node in widget_sources:
            w('\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
              % (build_file('widget', node), node.name, node.uid, node.name))
        for node in widget_resources:
            w('\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
              % (build_file('widget', node), node.name, node.uid, node.name))
        w('\t\t%s /* %s.appex in Embed Foundation Extensions */ = {isa = PBXBuildFile; '
          'fileRef = %s /* %s.appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };'
          % (widget_embed_build_file, WIDGET, widget_product, WIDGET))
    w('/* End PBXBuildFile section */')
    w('')

    if has_widget:
        w('/* Begin PBXContainerItemProxy section */')
        w('\t\t%s /* PBXContainerItemProxy */ = {' % widget_proxy)
        w('\t\t\tisa = PBXContainerItemProxy;')
        w('\t\t\tcontainerPortal = %s /* Project object */;' % project_uid)
        w('\t\t\tproxyType = 1;')
        w('\t\t\tremoteGlobalIDString = %s;' % widget_target)
        w('\t\t\tremoteInfo = %s;' % WIDGET)
        w('\t\t};')
        w('/* End PBXContainerItemProxy section */')
        w('')

        w('/* Begin PBXCopyFilesBuildPhase section */')
        w('\t\t%s /* Embed Foundation Extensions */ = {' % app_embed_phase)
        w('\t\t\tisa = PBXCopyFilesBuildPhase;')
        w('\t\t\tbuildActionMask = 2147483647;')
        w('\t\t\tdstPath = "";')
        w('\t\t\tdstSubfolderSpec = 13;')
        w('\t\t\tfiles = (')
        w('\t\t\t\t%s /* %s.appex in Embed Foundation Extensions */,' % (widget_embed_build_file, WIDGET))
        w('\t\t\t);')
        w('\t\t\tname = "Embed Foundation Extensions";')
        w('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
        w('\t\t};')
        w('/* End PBXCopyFilesBuildPhase section */')
        w('')

    w('/* Begin PBXFileReference section */')
    w('\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; '
      'includeInIndex = 0; path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; };' % (app_product, APP, APP))
    if has_widget:
        w('\t\t%s /* %s.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; '
          'includeInIndex = 0; path = %s.appex; sourceTree = BUILT_PRODUCTS_DIR; };'
          % (widget_product, WIDGET, WIDGET))

    def emit_refs(node):
        for child in node.children:
            if child.is_dir:
                emit_refs(child)
            else:
                w('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; '
                  'sourceTree = "<group>"; };' % (child.uid, child.name, file_type(child.name), child.name))
    emit_refs(app_root)
    if has_widget:
        emit_refs(widget_root)
    w('/* End PBXFileReference section */')
    w('')

    w('/* Begin PBXFrameworksBuildPhase section */')
    for phase in ([app_frameworks_phase, widget_frameworks_phase] if has_widget else [app_frameworks_phase]):
        w('\t\t%s /* Frameworks */ = {' % phase)
        w('\t\t\tisa = PBXFrameworksBuildPhase;')
        w('\t\t\tbuildActionMask = 2147483647;')
        w('\t\t\tfiles = (')
        w('\t\t\t);')
        w('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
        w('\t\t};')
    w('/* End PBXFrameworksBuildPhase section */')
    w('')

    w('/* Begin PBXGroup section */')
    w('\t\t%s = {' % main_group)
    w('\t\t\tisa = PBXGroup;')
    w('\t\t\tchildren = (')
    w('\t\t\t\t%s /* %s */,' % (app_root.uid, APP))
    if has_widget:
        w('\t\t\t\t%s /* %s */,' % (widget_root.uid, WIDGET))
    w('\t\t\t\t%s /* Products */,' % products_group)
    w('\t\t\t);')
    w('\t\t\tsourceTree = "<group>";')
    w('\t\t};')
    w('\t\t%s /* Products */ = {' % products_group)
    w('\t\t\tisa = PBXGroup;')
    w('\t\t\tchildren = (')
    w('\t\t\t\t%s /* %s.app */,' % (app_product, APP))
    if has_widget:
        w('\t\t\t\t%s /* %s.appex */,' % (widget_product, WIDGET))
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
    emit_groups(app_root)
    if has_widget:
        emit_groups(widget_root)
    w('/* End PBXGroup section */')
    w('')

    w('/* Begin PBXNativeTarget section */')
    w('\t\t%s /* %s */ = {' % (app_target, APP))
    w('\t\t\tisa = PBXNativeTarget;')
    w('\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget "%s" */;'
      % (app_cfg_list, APP))
    w('\t\t\tbuildPhases = (')
    w('\t\t\t\t%s /* Sources */,' % app_sources_phase)
    w('\t\t\t\t%s /* Frameworks */,' % app_frameworks_phase)
    w('\t\t\t\t%s /* Resources */,' % app_resources_phase)
    if has_widget:
        w('\t\t\t\t%s /* Embed Foundation Extensions */,' % app_embed_phase)
    w('\t\t\t);')
    w('\t\t\tbuildRules = (')
    w('\t\t\t);')
    w('\t\t\tdependencies = (')
    if has_widget:
        w('\t\t\t\t%s /* PBXTargetDependency */,' % widget_dependency)
    w('\t\t\t);')
    w('\t\t\tname = %s;' % APP)
    w('\t\t\tproductName = %s;' % APP)
    w('\t\t\tproductReference = %s /* %s.app */;' % (app_product, APP))
    w('\t\t\tproductType = "com.apple.product-type.application";')
    w('\t\t};')
    if has_widget:
        w('\t\t%s /* %s */ = {' % (widget_target, WIDGET))
        w('\t\t\tisa = PBXNativeTarget;')
        w('\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget "%s" */;'
          % (widget_cfg_list, WIDGET))
        w('\t\t\tbuildPhases = (')
        w('\t\t\t\t%s /* Sources */,' % widget_sources_phase)
        w('\t\t\t\t%s /* Frameworks */,' % widget_frameworks_phase)
        w('\t\t\t\t%s /* Resources */,' % widget_resources_phase)
        w('\t\t\t);')
        w('\t\t\tbuildRules = (')
        w('\t\t\t);')
        w('\t\t\tdependencies = (')
        w('\t\t\t);')
        w('\t\t\tname = %s;' % WIDGET)
        w('\t\t\tproductName = %s;' % WIDGET)
        w('\t\t\tproductReference = %s /* %s.appex */;' % (widget_product, WIDGET))
        w('\t\t\tproductType = "com.apple.product-type.app-extension";')
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
    w('\t\t\t\t\t%s = {' % app_target)
    w('\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;')
    w('\t\t\t\t\t};')
    if has_widget:
        w('\t\t\t\t\t%s = {' % widget_target)
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
    w('\t\t\tmainGroup = %s;' % main_group)
    w('\t\t\tproductRefGroup = %s /* Products */;' % products_group)
    w('\t\t\tprojectDirPath = "";')
    w('\t\t\tprojectRoot = "";')
    w('\t\t\ttargets = (')
    w('\t\t\t\t%s /* %s */,' % (app_target, APP))
    if has_widget:
        w('\t\t\t\t%s /* %s */,' % (widget_target, WIDGET))
    w('\t\t\t);')
    w('\t\t};')
    w('/* End PBXProject section */')
    w('')

    w('/* Begin PBXResourcesBuildPhase section */')
    w('\t\t%s /* Resources */ = {' % app_resources_phase)
    w('\t\t\tisa = PBXResourcesBuildPhase;')
    w('\t\t\tbuildActionMask = 2147483647;')
    w('\t\t\tfiles = (')
    for node in app_resources:
        w('\t\t\t\t%s /* %s in Resources */,' % (build_file('app', node), node.name))
    w('\t\t\t);')
    w('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    w('\t\t};')
    if has_widget:
        w('\t\t%s /* Resources */ = {' % widget_resources_phase)
        w('\t\t\tisa = PBXResourcesBuildPhase;')
        w('\t\t\tbuildActionMask = 2147483647;')
        w('\t\t\tfiles = (')
        for node in widget_resources:
            w('\t\t\t\t%s /* %s in Resources */,' % (build_file('widget', node), node.name))
        w('\t\t\t);')
        w('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
        w('\t\t};')
    w('/* End PBXResourcesBuildPhase section */')
    w('')

    w('/* Begin PBXSourcesBuildPhase section */')
    w('\t\t%s /* Sources */ = {' % app_sources_phase)
    w('\t\t\tisa = PBXSourcesBuildPhase;')
    w('\t\t\tbuildActionMask = 2147483647;')
    w('\t\t\tfiles = (')
    for node in app_sources:
        w('\t\t\t\t%s /* %s in Sources */,' % (build_file('app', node), node.name))
    w('\t\t\t);')
    w('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    w('\t\t};')
    if has_widget:
        w('\t\t%s /* Sources */ = {' % widget_sources_phase)
        w('\t\t\tisa = PBXSourcesBuildPhase;')
        w('\t\t\tbuildActionMask = 2147483647;')
        w('\t\t\tfiles = (')
        for node in widget_sources:
            w('\t\t\t\t%s /* %s in Sources */,' % (build_file('widget', node), node.name))
        w('\t\t\t);')
        w('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
        w('\t\t};')
    w('/* End PBXSourcesBuildPhase section */')
    w('')

    if has_widget:
        w('/* Begin PBXTargetDependency section */')
        w('\t\t%s /* PBXTargetDependency */ = {' % widget_dependency)
        w('\t\t\tisa = PBXTargetDependency;')
        w('\t\t\ttarget = %s /* %s */;' % (widget_target, WIDGET))
        w('\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;' % widget_proxy)
        w('\t\t};')
        w('/* End PBXTargetDependency section */')
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
    signing = [
        ('CODE_SIGN_IDENTITY', '""'),
        ('CODE_SIGN_STYLE', 'Manual'),
        ('CODE_SIGNING_ALLOWED', 'NO'),
        ('CODE_SIGNING_REQUIRED', 'NO'),
        ('DEVELOPMENT_TEAM', '""'),
        ('PROVISIONING_PROFILE_SPECIFIER', '""'),
    ]
    app_settings = signing + [
        ('ASSETCATALOG_COMPILER_APPICON_NAME', 'AppIcon'),
        ('ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME', 'AccentColor'),
        ('CODE_SIGN_ENTITLEMENTS', '%s/Resources/%s.entitlements' % (APP, APP)),
        ('CURRENT_PROJECT_VERSION', '1'),
        ('ENABLE_PREVIEWS', 'YES'),
        ('GENERATE_INFOPLIST_FILE', 'NO'),
        ('INFOPLIST_FILE', '%s/Resources/Info.plist' % APP),
        ('LD_RUNPATH_SEARCH_PATHS', '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)'),
        ('MARKETING_VERSION', '1.6'),
        ('PRODUCT_BUNDLE_IDENTIFIER', BUNDLE_ID),
        ('PRODUCT_NAME', '"$(TARGET_NAME)"'),
        ('SWIFT_EMIT_LOC_STRINGS', 'YES'),
        ('TARGETED_DEVICE_FAMILY', '"1,2"'),
    ]
    widget_settings = signing + [
        ('CODE_SIGN_ENTITLEMENTS', '%s/%s.entitlements' % (WIDGET, WIDGET)),
        ('CURRENT_PROJECT_VERSION', '1'),
        ('ENABLE_PREVIEWS', 'YES'),
        ('GENERATE_INFOPLIST_FILE', 'NO'),
        ('INFOPLIST_FILE', '%s/Info.plist' % WIDGET),
        ('LD_RUNPATH_SEARCH_PATHS', '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n'
                                    '\t\t\t\t\t"@executable_path/../../Frameworks",\n\t\t\t\t)'),
        ('MARKETING_VERSION', '1.6'),
        ('PRODUCT_BUNDLE_IDENTIFIER', WIDGET_BUNDLE_ID),
        ('PRODUCT_NAME', '"$(TARGET_NAME)"'),
        ('SKIP_INSTALL', 'YES'),
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
    emit_cfg(app_debug, 'Debug', app_settings)
    emit_cfg(app_release, 'Release', app_settings)
    if has_widget:
        emit_cfg(widget_debug, 'Debug', widget_settings)
        emit_cfg(widget_release, 'Release', widget_settings)
    w('/* End XCBuildConfiguration section */')
    w('')

    w('/* Begin XCConfigurationList section */')
    lists = [(proj_cfg_list, 'PBXProject "%s"' % APP, proj_debug, proj_release),
             (app_cfg_list, 'PBXNativeTarget "%s"' % APP, app_debug, app_release)]
    if has_widget:
        lists.append((widget_cfg_list, 'PBXNativeTarget "%s"' % WIDGET, widget_debug, widget_release))
    for cfg_list, kind, dbg, rel in lists:
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

    entry_template = """         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target}"
               BuildableName = "{product}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:{app}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>"""
    entries = [entry_template.format(target=app_target, product=APP + '.app', name=APP, app=APP)]
    if has_widget:
        entries.append(entry_template.format(target=widget_target, product=WIDGET + '.appex',
                                             name=WIDGET, app=APP))

    scheme = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
{entries}
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
            BlueprintIdentifier = "{app_target}"
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
            BlueprintIdentifier = "{app_target}"
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
""".replace('{entries}', '\n'.join(entries)).replace('{app_target}', app_target).replace('{app}', APP)

    with open(os.path.join(PROJ_DIR, 'xcshareddata', 'xcschemes', APP + '.xcscheme'), 'w') as fh:
        fh.write(scheme)

    print("Generated %s\n  app: %d sources, %d resources\n  widget: %d sources, %d resources"
          % (PROJ_DIR, len(app_sources), len(app_resources), len(widget_sources), len(widget_resources)))


if __name__ == '__main__':
    main()
