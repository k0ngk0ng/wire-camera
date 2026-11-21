import hashlib
import pathlib
import plistlib

root = pathlib.Path(__file__).resolve().parent.parent
project = root / 'iOS' / 'WireCamera.xcodeproj'
scheme_directory = project / 'xcshareddata' / 'xcschemes'
scheme_directory.mkdir(parents=True, exist_ok=True)
objects = {}


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(object_name, kind, **values):
    key = identifier(object_name)
    objects[key] = {'isa': kind, **values}
    return key


app_files = [str(path.relative_to(root / 'iOS')) for path in sorted((root / 'iOS').glob('*.swift'))]
app_files += ['../Shared/CameraRemoteCoding.swift', '../Sources/CameraPlaybackDay.swift']
test_files = ['../Tests/iOS/WireCameraUITests.swift']
children = []


def source_phase(name, files):
    build_files = []
    for source in files:
        reference = add(source, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=source, sourceTree='<group>')
        children.append(reference)
        build_files.append(add(name + source, 'PBXBuildFile', fileRef=reference))
    return add(name, 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=build_files, runOnlyForDeploymentPostprocessing=0)


app_sources = source_phase('app-sources', app_files)
test_sources = source_phase('test-sources', test_files)
asset = add('assets', 'PBXFileReference', lastKnownFileType='folder.assetcatalog', path='Assets.xcassets', sourceTree='<group>')
children.append(asset)
resources = add('resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=[add('asset-build', 'PBXBuildFile', fileRef=asset)], runOnlyForDeploymentPostprocessing=0)
app_product = add('app-product', 'PBXFileReference', explicitFileType='wrapper.application', path='WireCamera.app', sourceTree='BUILT_PRODUCTS_DIR')
test_product = add('test-product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', path='WireCameraUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
products = add('products', 'PBXGroup', children=[app_product, test_product], name='Products', sourceTree='<group>')
main_group = add('main-group', 'PBXGroup', children=children + [products], sourceTree='<group>')
base_settings = {'SDKROOT': 'iphoneos', 'SWIFT_VERSION': '5.0', 'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'TARGETED_DEVICE_FAMILY': '1', 'CODE_SIGN_STYLE': 'Automatic', 'ENABLE_DEBUG_DYLIB': 'NO', 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES', 'CLANG_ENABLE_MODULES': 'YES', 'SWIFT_STRICT_CONCURRENCY': 'minimal'}


def configurations(name, settings):
    configs = []
    for mode in ['Debug', 'Release']:
        values = dict(settings)
        values['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if mode == 'Debug' else '-O'
        values['DEBUG_INFORMATION_FORMAT'] = 'dwarf' if mode == 'Debug' else 'dwarf-with-dsym'
        if mode == 'Debug':
            values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        configs.append(add(name + mode, 'XCBuildConfiguration', name=mode, buildSettings=values))
    return add(name + '-configs', 'XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')


app_settings = dict(base_settings, PRODUCT_NAME='WireCamera', PRODUCT_BUNDLE_IDENTIFIER='com.wirecamera.iphone.k0ngk0ng', INFOPLIST_FILE='Info.plist', GENERATE_INFOPLIST_FILE='YES', MARKETING_VERSION='1.0.0', CURRENT_PROJECT_VERSION='1', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', SUPPORTS_MACCATALYST='NO')
test_settings = dict(base_settings, PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='com.wirecamera.iphone.k0ngk0ng.uitests', GENERATE_INFOPLIST_FILE='YES', TEST_TARGET_NAME='WireCamera')
app_target = add('app-target', 'PBXNativeTarget', name='WireCamera', buildConfigurationList=configurations('app', app_settings), buildPhases=[app_sources, resources], buildRules=[], dependencies=[], productName='WireCamera', productReference=app_product, productType='com.apple.product-type.application')
proxy = add('test-proxy', 'PBXContainerItemProxy', containerPortal=identifier('project'), proxyType=1, remoteGlobalIDString=app_target, remoteInfo='WireCamera')
dependency = add('test-dependency', 'PBXTargetDependency', target=app_target, targetProxy=proxy)
test_target = add('test-target', 'PBXNativeTarget', name='WireCameraUITests', buildConfigurationList=configurations('test', test_settings), buildPhases=[test_sources], buildRules=[], dependencies=[dependency], productName='WireCameraUITests', productReference=test_product, productType='com.apple.product-type.bundle.ui-testing')
project_id = add('project', 'PBXProject', attributes={'LastUpgradeCheck': '2720', 'TargetAttributes': {app_target: {'CreatedOnToolsVersion': '27.2', 'ProvisioningStyle': 'Automatic'}, test_target: {'CreatedOnToolsVersion': '27.2', 'TestTargetID': app_target, 'ProvisioningStyle': 'Automatic'}}}, buildConfigurationList=configurations('project', {}), compatibilityVersion='Xcode 14.0', developmentRegion='zh-Hans', hasScannedForEncodings=0, knownRegions=['en', 'zh-Hans', 'Base'], mainGroup=main_group, productRefGroup=products, projectDirPath='', projectRoot='', targets=[app_target, test_target])
(project / 'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion': '1', 'classes': {}, 'objectVersion': '56', 'objects': objects, 'rootObject': project_id}, sort_keys=False))
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2720" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="WireCamera.app" BlueprintName="WireCamera" ReferencedContainer="container:WireCamera.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="WireCameraUITests.xctest" BlueprintName="WireCameraUITests" ReferencedContainer="container:WireCamera.xcodeproj"/></TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="WireCamera.app" BlueprintName="WireCamera" ReferencedContainer="container:WireCamera.xcodeproj"/></BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(scheme_directory / 'WireCamera.xcscheme').write_text(scheme)
print(project)
