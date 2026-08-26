#!/usr/bin/env python3
"""Generates Packmule.xcodeproj: the app target plus the PackmuleWidgets
Live Activity extension (the Dynamic Island mule).

    python3 Scripts/gen_xcodeproj.py

Re-run after adding or removing source files. IDs derive from paths, so
re-generation only changes what actually changed. Layout:

    Packmule/         app sources (also compiles Shared/)
    Shared/           types both the app and the widget need
    PackmuleWidgets/  the widget extension (also compiles Shared/)
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = 'Packmule'
SHARED_DIR = 'Shared'
WIDGET_DIR = 'PackmuleWidgets'
WIDGET_NAME = 'PackmuleWidgets'
PROJECT_NAME = 'Packmule'
BUNDLE_ID = 'com.redfernsoutpost.packmule'
DEPLOYMENT_TARGET = '16.0'
WIDGET_DEPLOYMENT_TARGET = '16.2'

# (display name, repository URL, (requirement kind, version), [product names],
#  embed) — embed only DYNAMIC library products (AMSMB2); static ones (Citadel)
#  link into the binary and must not be copied. Citadel stays upToNextMinor:
#  its 0.11+ releases require iOS 17 and a forked swift-nio-ssh.
PACKAGES = [
    ('AMSMB2', 'https://github.com/amosavian/AMSMB2.git',
     ('upToNextMajorVersion', '3.0.0'), ['AMSMB2'], True),
    ('Citadel', 'https://github.com/orlandos-nl/Citadel.git',
     ('upToNextMinorVersion', '0.10.1'), ['Citadel'], False),
]

FILE_TYPES = {
    '.swift': 'sourcecode.swift',
    '.xcassets': 'folder.assetcatalog',
    '.plist': 'text.plist.xml',
    '.entitlements': 'text.plist.entitlements',
    '.txt': 'text',
    '.md': 'net.daringfireball.markdown',
}
SOURCE_EXTS = {'.swift'}
RESOURCE_EXTS = {'.xcassets', '.txt'}


def uid(key):
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()


def q(s):
    """Quote a pbxproj string when needed."""
    if s and all(c.isalnum() or c in '._/' for c in s) and not s.startswith('.'):
        return s
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


class Project:
    def __init__(self):
        self.objects = {}   # id -> (isa, dict-as-string)

    def add(self, oid, isa, body):
        self.objects[oid] = (isa, body)
        return oid

    def group(self, rel_path, name, children, source_tree='<group>'):
        oid = uid('namedgroup:' + name)
        kids = ' '.join(f'{c},' for c in children)
        path_part = f'path = {q(rel_path)}; ' if rel_path else ''
        self.add(oid, 'PBXGroup',
                 f'{{isa = PBXGroup; children = ({kids}); name = {q(name)}; {path_part}sourceTree = {q(source_tree)}; }}')
        return oid

    def walk(self, dir_rel, ns, sources, resources):
        """Adds file refs + groups for dir_rel; appends build-file ids (unique
        per `ns`, so two targets can compile the same file) into the lists."""
        abs_dir = os.path.join(ROOT, dir_rel)
        children = []
        for entry in sorted(os.listdir(abs_dir)):
            if entry.startswith('.'):
                continue
            rel = os.path.join(dir_rel, entry).replace('\\', '/')
            ext = os.path.splitext(entry)[1]
            if os.path.isdir(os.path.join(abs_dir, entry)) and ext not in FILE_TYPES:
                children.append(self.walk(rel, ns, sources, resources))
                continue
            if ext not in FILE_TYPES:
                continue
            ref = uid('fileref:' + rel)
            self.add(ref, 'PBXFileReference',
                     f'{{isa = PBXFileReference; lastKnownFileType = {FILE_TYPES[ext]}; path = {q(entry)}; sourceTree = "<group>"; }}')
            children.append(ref)
            bucket = sources if ext in SOURCE_EXTS else (resources if ext in RESOURCE_EXTS else None)
            if bucket is not None:
                bf = uid(f'buildfile:{ns}:{rel}')
                self.add(bf, 'PBXBuildFile', f'{{isa = PBXBuildFile; fileRef = {ref}; }}')
                bucket.append(bf)
        oid = uid('group:' + dir_rel)
        kids = ' '.join(f'{c},' for c in children)
        self.add(oid, 'PBXGroup',
                 f'{{isa = PBXGroup; children = ({kids}); path = {q(os.path.basename(dir_rel))}; sourceTree = "<group>"; }}')
        return oid

    def phase(self, key, isa, files, extra=''):
        oid = uid(key)
        items = ' '.join(f'{f},' for f in files)
        self.add(oid, isa,
                 f'{{isa = {isa}; buildActionMask = 2147483647; {extra}files = ({items}); runOnlyForDeploymentPostprocessing = 0; }}')
        return oid


def build_settings(common):
    lines = []
    for k in sorted(common):
        v = common[k]
        if isinstance(v, list):
            items = ' '.join(f'{q(i)},' for i in v)
            lines.append(f'\t\t\t\t{k} = ({items});')
        else:
            lines.append(f'\t\t\t\t{k} = {q(str(v))};')
    return '\n'.join(lines)


def main():
    p = Project()
    project_id = uid('project')

    # ---- sources --------------------------------------------------------
    app_sources, app_resources = [], []
    app_group = p.walk(SRC_DIR, 'app', app_sources, app_resources)
    shared_group = p.walk(SHARED_DIR, 'app', app_sources, app_resources)

    widget_sources, widget_resources = [], []
    widget_group = p.walk(WIDGET_DIR, 'widget', widget_sources, widget_resources)
    p.walk(SHARED_DIR, 'widget', widget_sources, widget_resources)

    # ---- Swift packages (app target only) -------------------------------
    # AMSMB2's product is a DYNAMIC library: link AND embed it, or the app
    # dies at launch (dyld cannot find @rpath/AMSMB2.framework/AMSMB2).
    package_refs = []
    product_dep_ids = []
    link_files = []
    embed_files = []
    for name, url, (req_kind, version), products, embed in PACKAGES:
        pkg_id = uid('pkgref:' + url)
        p.add(pkg_id, 'XCRemoteSwiftPackageReference',
              f'{{isa = XCRemoteSwiftPackageReference; repositoryURL = {q(url)}; '
              f'requirement = {{kind = {req_kind}; minimumVersion = {version}; }}; }}')
        package_refs.append(pkg_id)
        for product in products:
            dep_id = uid('pkgproduct:' + url + ':' + product)
            p.add(dep_id, 'XCSwiftPackageProductDependency',
                  f'{{isa = XCSwiftPackageProductDependency; package = {pkg_id}; productName = {product}; }}')
            product_dep_ids.append(dep_id)
            bf = uid('buildfile:frameworks:' + product)
            p.add(bf, 'PBXBuildFile', f'{{isa = PBXBuildFile; productRef = {dep_id}; }}')
            link_files.append(bf)
            if embed:
                ebf = uid('buildfile:embed:' + product)
                p.add(ebf, 'PBXBuildFile',
                      f'{{isa = PBXBuildFile; productRef = {dep_id}; '
                      f'settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }}')
                embed_files.append(ebf)

    # ---- products -------------------------------------------------------
    app_ref = uid('product:app')
    p.add(app_ref, 'PBXFileReference',
          f'{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {PROJECT_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }}')
    appex_ref = uid('product:appex')
    p.add(appex_ref, 'PBXFileReference',
          f'{{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = {WIDGET_NAME}.appex; sourceTree = BUILT_PRODUCTS_DIR; }}')
    products_group = p.group('', 'Products', [app_ref, appex_ref])

    # ---- scripts in the navigator ---------------------------------------
    script_refs = []
    for name in ['gen_xcodeproj.py', 'gen_icon.py']:
        rel = f'Scripts/{name}'
        if os.path.exists(os.path.join(ROOT, rel)):
            r = uid('fileref:' + rel)
            p.add(r, 'PBXFileReference', f'{{isa = PBXFileReference; lastKnownFileType = text.script.python; path = {q(name)}; sourceTree = "<group>"; }}')
            script_refs.append(r)
    readme_ref = uid('fileref:README.md')
    p.add(readme_ref, 'PBXFileReference', '{isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = README.md; sourceTree = "<group>"; }')
    scripts_group = p.group('Scripts', 'Scripts', script_refs)

    main_group = p.group('', PROJECT_NAME,
                         [app_group, shared_group, widget_group, scripts_group, readme_ref, products_group])

    # ---- app phases -----------------------------------------------------
    app_sources_phase = p.phase('phase:sources', 'PBXSourcesBuildPhase', app_sources)
    app_frameworks_phase = p.phase('phase:frameworks', 'PBXFrameworksBuildPhase', link_files)
    app_resources_phase = p.phase('phase:resources', 'PBXResourcesBuildPhase', app_resources)
    embed_fw_phase = p.phase('phase:embed', 'PBXCopyFilesBuildPhase', embed_files,
                             extra='dstPath = ""; dstSubfolderSpec = 10; name = "Embed Frameworks"; ')

    appex_bf = uid('buildfile:embedext:widgets')
    p.add(appex_bf, 'PBXBuildFile',
          f'{{isa = PBXBuildFile; fileRef = {appex_ref}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }}')
    embed_ext_phase = p.phase('phase:embedext', 'PBXCopyFilesBuildPhase', [appex_bf],
                              extra='dstPath = ""; dstSubfolderSpec = 13; name = "Embed Foundation Extensions"; ')

    # ---- widget phases --------------------------------------------------
    w_sources_phase = p.phase('phase:w:sources', 'PBXSourcesBuildPhase', widget_sources)
    w_frameworks_phase = p.phase('phase:w:frameworks', 'PBXFrameworksBuildPhase', [])
    w_resources_phase = p.phase('phase:w:resources', 'PBXResourcesBuildPhase', widget_resources)

    # ---- configurations -------------------------------------------------
    project_common = {
        'ALWAYS_SEARCH_USER_PATHS': 'NO',
        'CLANG_ANALYZER_NONNULL': 'YES',
        'CLANG_ENABLE_MODULES': 'YES',
        'CLANG_ENABLE_OBJC_ARC': 'YES',
        'CLANG_ENABLE_OBJC_WEAK': 'YES',
        'CLANG_WARN_DOCUMENTATION_COMMENTS': 'NO',
        'CLANG_WARN_UNGUARDED_AVAILABILITY': 'YES_AGGRESSIVE',
        'COPY_PHASE_STRIP': 'NO',
        'ENABLE_STRICT_OBJC_MSGSEND': 'YES',
        'ENABLE_USER_SCRIPT_SANDBOXING': 'NO',
        'GCC_C_LANGUAGE_STANDARD': 'gnu11',
        'GCC_NO_COMMON_BLOCKS': 'YES',
        'IPHONEOS_DEPLOYMENT_TARGET': DEPLOYMENT_TARGET,
        'LOCALIZATION_PREFERS_STRING_CATALOGS': 'YES',
        'SDKROOT': 'iphoneos',
        'SWIFT_VERSION': '5.0',
        'TARGETED_DEVICE_FAMILY': '1,2',
    }
    project_debug = dict(project_common, **{
        'DEBUG_INFORMATION_FORMAT': 'dwarf',
        'ENABLE_TESTABILITY': 'YES',
        'GCC_OPTIMIZATION_LEVEL': '0',
        'GCC_PREPROCESSOR_DEFINITIONS': ['DEBUG=1', '$(inherited)'],
        'ONLY_ACTIVE_ARCH': 'YES',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS': ['DEBUG', '$(inherited)'],
        'SWIFT_OPTIMIZATION_LEVEL': '-Onone',
    })
    project_release = dict(project_common, **{
        'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym',
        'ENABLE_NS_ASSERTIONS': 'NO',
        'SWIFT_COMPILATION_MODE': 'wholemodule',
        'SWIFT_OPTIMIZATION_LEVEL': '-O',
        'VALIDATE_PRODUCT': 'YES',
    })

    shared_target_settings = {
        'CODE_SIGN_STYLE': 'Automatic',
        'CURRENT_PROJECT_VERSION': '1',
        'DEVELOPMENT_TEAM': '',
        'GENERATE_INFOPLIST_FILE': 'NO',
        'MARKETING_VERSION': '1.0',
        'PRODUCT_NAME': '$(TARGET_NAME)',
        'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
        'SUPPORTS_MACCATALYST': 'NO',
        # SIDELOAD gates the personal server seed; App Store submissions build
        # with: xcodebuild SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited)'
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS': ['SIDELOAD', '$(inherited)'],
        'SWIFT_EMIT_LOC_STRINGS': 'YES',
        'SWIFT_STRICT_CONCURRENCY': 'minimal',
        'VERSIONING_SYSTEM': 'apple-generic',
    }
    app_target_settings = dict(shared_target_settings, **{
        'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
        'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME': 'AccentColor',
        'CODE_SIGN_ENTITLEMENTS': f'{SRC_DIR}/Resources/{PROJECT_NAME}.entitlements',
        'INFOPLIST_FILE': f'{SRC_DIR}/Resources/Info.plist',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks'],
        'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID,
    })
    widget_target_settings = dict(shared_target_settings, **{
        'INFOPLIST_FILE': f'{WIDGET_DIR}/Info.plist',
        'IPHONEOS_DEPLOYMENT_TARGET': WIDGET_DEPLOYMENT_TARGET,
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks',
                                    '@executable_path/../../Frameworks'],
        'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID + '.widgets',
        'SKIP_INSTALL': 'YES',
    })

    def config(key, name, settings):
        oid = uid(key)
        p.add(oid, 'XCBuildConfiguration',
              f'{{isa = XCBuildConfiguration; buildSettings = {{\n{build_settings(settings)}\n\t\t\t}}; name = {name}; }}')
        return oid

    def config_list(key, configs):
        oid = uid(key)
        items = ' '.join(f'{c},' for c in configs)
        p.add(oid, 'XCConfigurationList',
              f'{{isa = XCConfigurationList; buildConfigurations = ({items}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')
        return oid

    proj_configs = config_list('configlist:project', [
        config('config:project:Debug', 'Debug', project_debug),
        config('config:project:Release', 'Release', project_release),
    ])
    app_configs = config_list('configlist:target', [
        config('config:target:Debug', 'Debug', app_target_settings),
        config('config:target:Release', 'Release', app_target_settings),
    ])
    widget_configs = config_list('configlist:widget', [
        config('config:widget:Debug', 'Debug', widget_target_settings),
        config('config:widget:Release', 'Release', widget_target_settings),
    ])

    # ---- targets --------------------------------------------------------
    widget_target = uid('target:widget')
    p.add(widget_target, 'PBXNativeTarget',
          f'{{isa = PBXNativeTarget; buildConfigurationList = {widget_configs}; '
          f'buildPhases = ({w_sources_phase}, {w_frameworks_phase}, {w_resources_phase}, ); '
          f'buildRules = (); dependencies = (); name = {WIDGET_NAME}; productName = {WIDGET_NAME}; '
          f'productReference = {appex_ref}; productType = "com.apple.product-type.app-extension"; }}')

    proxy = uid('proxy:widget')
    p.add(proxy, 'PBXContainerItemProxy',
          f'{{isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; '
          f'remoteGlobalIDString = {widget_target}; remoteInfo = {WIDGET_NAME}; }}')
    widget_dep = uid('dep:widget')
    p.add(widget_dep, 'PBXTargetDependency',
          f'{{isa = PBXTargetDependency; target = {widget_target}; targetProxy = {proxy}; }}')

    app_target = uid('target:app')
    product_deps = ' '.join(f'{d},' for d in product_dep_ids)
    p.add(app_target, 'PBXNativeTarget',
          f'{{isa = PBXNativeTarget; buildConfigurationList = {app_configs}; '
          f'buildPhases = ({app_sources_phase}, {app_frameworks_phase}, {app_resources_phase}, {embed_fw_phase}, {embed_ext_phase}, ); '
          f'buildRules = (); dependencies = ({widget_dep}, ); name = {PROJECT_NAME}; '
          f'packageProductDependencies = ({product_deps}); productName = {PROJECT_NAME}; '
          f'productReference = {app_ref}; productType = "com.apple.product-type.application"; }}')

    pkg_list = ' '.join(f'{r},' for r in package_refs)
    p.add(project_id, 'PBXProject',
          f'{{isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1500; LastUpgradeCheck = 1500; '
          f'TargetAttributes = {{ {app_target} = {{ CreatedOnToolsVersion = 15.0; }}; {widget_target} = {{ CreatedOnToolsVersion = 15.0; }}; }}; }}; '
          f'buildConfigurationList = {proj_configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; '
          f'knownRegions = (en, Base, ); mainGroup = {main_group}; packageReferences = ({pkg_list}); productRefGroup = {products_group}; '
          f'projectDirPath = ""; projectRoot = ""; targets = ({app_target}, {widget_target}, ); }}')

    # ---- emit -----------------------------------------------------------
    out = ['// !$*UTF8*$!', '{', '\tarchiveVersion = 1;', '\tclasses = {', '\t};', '\tobjectVersion = 56;', '\tobjects = {']
    by_isa = {}
    for oid, (isa, body) in p.objects.items():
        by_isa.setdefault(isa, []).append((oid, body))
    for isa in sorted(by_isa):
        out.append(f'\n/* Begin {isa} section */')
        for oid, body in sorted(by_isa[isa]):
            out.append(f'\t\t{oid} = {body};')
        out.append(f'/* End {isa} section */')
    out += ['\t};', f'\trootObject = {project_id};', '}', '']

    proj_dir = os.path.join(ROOT, f'{PROJECT_NAME}.xcodeproj')
    os.makedirs(os.path.join(proj_dir, 'xcshareddata', 'xcschemes'), exist_ok=True)
    with open(os.path.join(proj_dir, 'project.pbxproj'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(out))

    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "{PROJECT_NAME}.app" BlueprintName = "{PROJECT_NAME}" ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables/>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "{PROJECT_NAME}.app" BlueprintName = "{PROJECT_NAME}" ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "{PROJECT_NAME}.app" BlueprintName = "{PROJECT_NAME}" ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj"/>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"/>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
</Scheme>
'''
    with open(os.path.join(proj_dir, 'xcshareddata', 'xcschemes', f'{PROJECT_NAME}.xcscheme'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(scheme)

    print(f'Wrote {proj_dir} (app: {len(app_sources)} sources, {len(app_resources)} resources; '
          f'widget: {len(widget_sources)} sources)')


if __name__ == '__main__':
    main()
