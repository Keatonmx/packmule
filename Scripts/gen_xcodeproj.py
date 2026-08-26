#!/usr/bin/env python3
"""Generates Packmule.xcodeproj from the files under Packmule/.

    python3 Scripts/gen_xcodeproj.py

Re-run after adding or removing source files. IDs are derived from paths, so
re-generation only changes what actually changed. Swift Package dependencies
are declared in PACKAGES below and resolved by xcodebuild on first build.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = 'Packmule'
PROJECT_NAME = 'Packmule'
BUNDLE_ID = 'com.redfernsoutpost.packmule'
DEPLOYMENT_TARGET = '16.0'

# (display name, repository URL, (requirement kind, version), [product names], embed)
# embed=True copies the product into the app's Frameworks/ folder — required
# for packages whose product is declared dynamic (AMSMB2); static products
# (Citadel) must NOT be embedded. Citadel is pinned upToNextMinor because its
# 0.11+ releases require iOS 17 and a forked swift-nio-ssh.
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
        self.build_files = {'sources': [], 'resources': [], 'frameworks': []}

    def add(self, oid, isa, body):
        self.objects[oid] = (isa, body)
        return oid

    # ---- groups / files -------------------------------------------------
    def group(self, rel_path, name, children, source_tree='<group>'):
        oid = uid('namedgroup:' + name)
        kids = ' '.join(f'{c},' for c in children)
        path_part = f'path = {q(rel_path)}; ' if rel_path else ''
        self.add(oid, 'PBXGroup',
                 f'{{isa = PBXGroup; children = ({kids}); name = {q(name)}; {path_part}sourceTree = {q(source_tree)}; }}')
        return oid

    def build_file(self, phase, file_ref, rel_path):
        oid = uid(f'buildfile:{phase}:{rel_path}')
        self.add(oid, 'PBXBuildFile', f'{{isa = PBXBuildFile; fileRef = {file_ref}; }}')
        self.build_files[phase].append(oid)
        return oid

    def walk(self, dir_rel):
        """Returns the group id for dir_rel, creating groups for children."""
        abs_dir = os.path.join(ROOT, dir_rel)
        children = []
        for entry in sorted(os.listdir(abs_dir)):
            if entry.startswith('.'):
                continue
            rel = os.path.join(dir_rel, entry).replace('\\', '/')
            ext = os.path.splitext(entry)[1]
            if os.path.isdir(os.path.join(abs_dir, entry)) and ext not in FILE_TYPES:
                children.append(self.walk(rel))
                continue
            if ext not in FILE_TYPES:
                continue
            ref = uid('fileref:' + rel)
            self.add(ref, 'PBXFileReference',
                     f'{{isa = PBXFileReference; lastKnownFileType = {FILE_TYPES[ext]}; path = {q(entry)}; sourceTree = "<group>"; }}')
            children.append(ref)
            if ext in SOURCE_EXTS:
                self.build_file('sources', ref, rel)
            elif ext in RESOURCE_EXTS:
                self.build_file('resources', ref, rel)
        oid = uid('group:' + dir_rel)
        kids = ' '.join(f'{c},' for c in children)
        self.add(oid, 'PBXGroup',
                 f'{{isa = PBXGroup; children = ({kids}); path = {q(os.path.basename(dir_rel))}; sourceTree = "<group>"; }}')
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

    # Sources under Packmule/
    app_group = p.walk(SRC_DIR)

    # Swift packages. AMSMB2's product is a DYNAMIC library, so besides linking
    # it we must copy it into the app's Frameworks/ folder; a hand-rolled
    # pbxproj gets no auto-embedding, and without it the app dies at launch
    # (dyld: Library not loaded @rpath/AMSMB2.framework/AMSMB2).
    package_refs = []
    product_dep_ids = []
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
            p.build_files['frameworks'].append(bf)
            if embed:
                ebf = uid('buildfile:embed:' + product)
                p.add(ebf, 'PBXBuildFile',
                      f'{{isa = PBXBuildFile; productRef = {dep_id}; '
                      f'settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }}')
                embed_files.append(ebf)

    # Product
    app_ref = uid('product:app')
    p.add(app_ref, 'PBXFileReference',
          f'{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {PROJECT_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }}')
    products_group = p.group('', 'Products', [app_ref])

    # Scripts as plain references (handy in the navigator)
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

    main_group = p.group('', PROJECT_NAME, [app_group, scripts_group, readme_ref, products_group])

    # Build phases
    def phase(oid_key, isa, files):
        oid = uid(oid_key)
        items = ' '.join(f'{f},' for f in files)
        p.add(oid, isa, f'{{isa = {isa}; buildActionMask = 2147483647; files = ({items}); runOnlyForDeploymentPostprocessing = 0; }}')
        return oid

    sources_phase = phase('phase:sources', 'PBXSourcesBuildPhase', p.build_files['sources'])
    frameworks_phase = phase('phase:frameworks', 'PBXFrameworksBuildPhase', p.build_files['frameworks'])
    resources_phase = phase('phase:resources', 'PBXResourcesBuildPhase', p.build_files['resources'])

    embed_items = ' '.join(f'{f},' for f in embed_files)
    embed_phase = uid('phase:embed')
    p.add(embed_phase, 'PBXCopyFilesBuildPhase',
          f'{{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; '
          f'dstSubfolderSpec = 10; files = ({embed_items}); name = "Embed Frameworks"; '
          f'runOnlyForDeploymentPostprocessing = 0; }}')

    # Build configurations
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
    target_common = {
        'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
        'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME': 'AccentColor',
        'CODE_SIGN_ENTITLEMENTS': f'{SRC_DIR}/Resources/{PROJECT_NAME}.entitlements',
        'CODE_SIGN_STYLE': 'Automatic',
        'CURRENT_PROJECT_VERSION': '1',
        'DEVELOPMENT_TEAM': '',
        'GENERATE_INFOPLIST_FILE': 'NO',
        'INFOPLIST_FILE': f'{SRC_DIR}/Resources/Info.plist',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks'],
        'MARKETING_VERSION': '1.0',
        'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID,
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

    def config(key, name, settings):
        oid = uid(key)
        p.add(oid, 'XCBuildConfiguration',
              f'{{isa = XCBuildConfiguration; buildSettings = {{\n{build_settings(settings)}\n\t\t\t}}; name = {name}; }}')
        return oid

    proj_debug = config('config:project:Debug', 'Debug', project_debug)
    proj_release = config('config:project:Release', 'Release', project_release)
    tgt_debug = config('config:target:Debug', 'Debug', target_common)
    tgt_release = config('config:target:Release', 'Release', target_common)

    def config_list(key, configs):
        oid = uid(key)
        items = ' '.join(f'{c},' for c in configs)
        p.add(oid, 'XCConfigurationList',
              f'{{isa = XCConfigurationList; buildConfigurations = ({items}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')
        return oid

    proj_configs = config_list('configlist:project', [proj_debug, proj_release])
    tgt_configs = config_list('configlist:target', [tgt_debug, tgt_release])

    target = uid('target:app')
    product_deps = ' '.join(f'{d},' for d in product_dep_ids)
    p.add(target, 'PBXNativeTarget',
          f'{{isa = PBXNativeTarget; buildConfigurationList = {tgt_configs}; buildPhases = ({sources_phase}, {frameworks_phase}, {resources_phase}, {embed_phase}, ); '
          f'buildRules = (); dependencies = (); name = {PROJECT_NAME}; packageProductDependencies = ({product_deps}); productName = {PROJECT_NAME}; '
          f'productReference = {app_ref}; productType = "com.apple.product-type.application"; }}')

    project = uid('project')
    pkg_list = ' '.join(f'{r},' for r in package_refs)
    p.add(project, 'PBXProject',
          f'{{isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1500; LastUpgradeCheck = 1500; '
          f'TargetAttributes = {{ {target} = {{ CreatedOnToolsVersion = 15.0; }}; }}; }}; buildConfigurationList = {proj_configs}; '
          f'compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); '
          f'mainGroup = {main_group}; packageReferences = ({pkg_list}); productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = ({target}, ); }}')

    # Emit
    out = ['// !$*UTF8*$!', '{', '\tarchiveVersion = 1;', '\tclasses = {', '\t};', '\tobjectVersion = 56;', '\tobjects = {']
    by_isa = {}
    for oid, (isa, body) in p.objects.items():
        by_isa.setdefault(isa, []).append((oid, body))
    for isa in sorted(by_isa):
        out.append(f'\n/* Begin {isa} section */')
        for oid, body in sorted(by_isa[isa]):
            out.append(f'\t\t{oid} = {body};')
        out.append(f'/* End {isa} section */')
    out += ['\t};', f'\trootObject = {project};', '}', '']

    proj_dir = os.path.join(ROOT, f'{PROJECT_NAME}.xcodeproj')
    os.makedirs(os.path.join(proj_dir, 'xcshareddata', 'xcschemes'), exist_ok=True)
    with open(os.path.join(proj_dir, 'project.pbxproj'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(out))

    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target}" BuildableName = "{PROJECT_NAME}.app" BlueprintName = "{PROJECT_NAME}" ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables/>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target}" BuildableName = "{PROJECT_NAME}.app" BlueprintName = "{PROJECT_NAME}" ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target}" BuildableName = "{PROJECT_NAME}.app" BlueprintName = "{PROJECT_NAME}" ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj"/>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"/>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
</Scheme>
'''
    with open(os.path.join(proj_dir, 'xcshareddata', 'xcschemes', f'{PROJECT_NAME}.xcscheme'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(scheme)

    n_src = len(p.build_files['sources'])
    print(f'Wrote {proj_dir} ({n_src} source files, {len(p.build_files["resources"])} resources)')


if __name__ == '__main__':
    main()
