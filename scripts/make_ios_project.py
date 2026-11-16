#!/usr/bin/env python3
"""Generates iOS/plickass.xcodeproj, its Info.plist and asset catalog.

Run from anywhere: python3 scripts/make_ios_project.py
Set PLICKASS_APPLE_TEAM to sign with your team (kept from the previous project otherwise).
"""
import hashlib, json, os, plistlib, re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / 'iOS'
VERSION = (ROOT / 'VERSION').read_text().strip()
BUILD = '1'


def assets():
    from PIL import Image
    catalog = IOS / 'App/Assets.xcassets'
    icon_set, logo_set = catalog / 'AppIcon.appiconset', catalog / 'Logo.imageset'
    for folder in (icon_set, logo_set):
        folder.mkdir(parents=True, exist_ok=True)
    source = Image.open(ROOT / 'docs/AppIcon-1024.png').convert('RGBA')
    # The App Store icon has no transparency: put it on the brand's coal.
    flat = Image.new('RGB', source.size, (38, 30, 23))
    flat.paste(source, mask=source.split()[3])
    flat.save(icon_set / 'AppIcon-1024.png')
    source.resize((512, 512), Image.LANCZOS).save(logo_set / 'Logo.png')
    (catalog / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}))
    (icon_set / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'AppIcon-1024.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2))
    (logo_set / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'Logo.png', 'idiom': 'universal'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2))
    accent = catalog / 'AccentColor.colorset'
    accent.mkdir(exist_ok=True)
    (accent / 'Contents.json').write_text(json.dumps({'colors': [{'idiom': 'universal', 'color': {'color-space': 'srgb', 'components': {'red': '0.961', 'green': '0.690', 'blue': '0.235', 'alpha': '1.0'}}}], 'info': {'author': 'xcode', 'version': 1}}))


def generate():
    project_name = 'plickass.xcodeproj'
    project_dir = IOS / project_name
    previous = (project_dir / 'project.pbxproj').read_text() if (project_dir / 'project.pbxproj').exists() else ''
    team_match = re.search(r'DEVELOPMENT_TEAM\s*=\s*"?([A-Z0-9]{10})"?;', previous)
    team = os.environ.get('PLICKASS_APPLE_TEAM') or (team_match.group(1) if team_match else '')
    sources = [str(p.relative_to(IOS)) for part in ['App', 'Core'] for p in sorted((IOS / part).glob('*.swift'))]
    resources = ['App/Assets.xcassets']
    objects = {}

    def uid(value):
        return hashlib.sha1(value.encode()).hexdigest()[:24].upper()

    def add(key, value):
        objects[uid(key)] = value
        return uid(key)

    def q(value):
        return json.dumps(str(value))

    files, builds, resource_builds = [], [], []
    for path in sources + resources:
        kind = 'sourcecode.swift' if path.endswith('.swift') else 'folder.assetcatalog'
        ref = add('file:' + path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = SOURCE_ROOT;')
        files.append(ref)
        build = add('build:' + path, f'isa = PBXBuildFile; fileRef = {ref};')
        (builds if path in sources else resource_builds).append(build)
    product = add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = plickass.app; sourceTree = BUILT_PRODUCTS_DIR;')
    products = add('products', f'isa = PBXGroup; children = ({product}); name = Products; sourceTree = "<group>";')
    main = add('main', f'isa = PBXGroup; children = ({",".join(files + [products])}); sourceTree = "<group>";')
    phases = []
    for key, kind, ids in [('sources', 'Sources', builds), ('frameworks', 'Frameworks', []), ('resources', 'Resources', resource_builds)]:
        phases.append(add(key, f'isa = PBX{kind}BuildPhase; buildActionMask = 2147483647; files = ({",".join(ids)}); runOnlyForDeploymentPostprocessing = 0;'))
    project_configs, target_configs = [], []
    for mode in ['Debug', 'Release']:
        values = dict(IPHONEOS_DEPLOYMENT_TARGET='17.0', SDKROOT='iphoneos', SWIFT_VERSION='5.0', CLANG_ENABLE_MODULES='YES',
                      ENABLE_USER_SCRIPT_SANDBOXING='YES', SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O',
                      DEBUG_INFORMATION_FORMAT='dwarf' if mode == 'Debug' else 'dwarf-with-dsym',
                      SWIFT_COMPILATION_MODE='singlefile' if mode == 'Debug' else 'wholemodule',
                      SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if mode == 'Debug' else '')
        target = dict(PRODUCT_BUNDLE_IDENTIFIER='com.dustalexw.plickass.ios', PRODUCT_NAME='plickass', INFOPLIST_FILE='Info.plist',
                      CODE_SIGN_STYLE='Automatic', DEVELOPMENT_TEAM=team, TARGETED_DEVICE_FAMILY='1,2',
                      SUPPORTED_PLATFORMS='iphoneos iphonesimulator', SUPPORTS_MACCATALYST='NO',
                      ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME='AccentColor',
                      LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks', ENABLE_TESTABILITY='YES' if mode == 'Debug' else 'NO')
        for category, settings, ids in [('project', values, project_configs), ('target', target, target_configs)]:
            body = ''.join(k + ' = ' + q(v) + ';' for k, v in settings.items())
            ids.append(add(category + mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{{body}}};'))

    def configs(key, ids):
        return add(key, f'isa = XCConfigurationList; buildConfigurations = ({",".join(ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    pc, tc = configs('projectconfig', project_configs), configs('targetconfig', target_configs)
    app = add('app', f'isa = PBXNativeTarget; buildConfigurationList = {tc}; buildPhases = ({",".join(phases)}); buildRules = (); dependencies = (); name = plickass; productName = plickass; productReference = {product}; productType = "com.apple.product-type.application";')
    project = add('project', f'isa = PBXProject; attributes = {{LastUpgradeCheck = 1600; TargetAttributes = {{{app} = {{CreatedOnToolsVersion = 16.0; ProvisioningStyle = Automatic; }};}};}}; buildConfigurationList = {pc}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({app});')
    project_dir.mkdir(exist_ok=True)
    (project_dir / 'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + ''.join(key + ' = {' + value + '};\n' for key, value in objects.items()) + '};rootObject = ' + project + ';}\n')
    schemes = project_dir / 'xcshareddata/xcschemes'
    schemes.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="plickass.app" BlueprintName="plickass" ReferencedContainer="container:{project_name}"/>'
    (schemes / 'plickass.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
    info = dict(CFBundleDisplayName='plickass', CFBundleName='plickass', CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)',
                CFBundleExecutable='$(EXECUTABLE_NAME)', CFBundlePackageType='APPL', CFBundleShortVersionString=VERSION,
                CFBundleVersion=BUILD, LSRequiresIPhoneOS=True, UILaunchScreen={},
                UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False},
                # Downloads appear in Files under On My iPhone › plickass.
                UIFileSharingEnabled=True, LSSupportsOpeningDocumentsInPlace=True,
                CFBundleURLTypes=[{'CFBundleURLName': 'com.dustalexw.plickass.signin', 'CFBundleURLSchemes': ['plickass']}],
                NSLocalNetworkUsageDescription='plickass connects to your Plex Media Server on this network to list and download your music.',
                NSBonjourServices=['_plexmediasvr._tcp'],
                NSAppTransportSecurity={'NSAllowsLocalNetworking': True},
                ITSAppUsesNonExemptEncryption=False,
                UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'])
    info['UISupportedInterfaceOrientations~ipad'] = info['UISupportedInterfaceOrientations'] + ['UIInterfaceOrientationPortraitUpsideDown']
    with (IOS / 'Info.plist').open('wb') as file:
        plistlib.dump(info, file)
    print(f'Generated iOS/{project_name}: {len(sources)} source files, version {VERSION}' + (f', team {team}' if team else ', no signing team'))


if __name__ == '__main__':
    assets()
    generate()
