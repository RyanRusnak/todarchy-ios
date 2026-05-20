#!/usr/bin/env ruby
require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path(File.dirname(__FILE__))
PROJECT_PATH = File.join(ROOT, 'todarchy.xcodeproj')
APP_DIR = File.join(ROOT, 'todarchy')
INFO_PLIST_PATH = File.join(APP_DIR, 'Info.plist')

File.delete(PROJECT_PATH) if File.exist?(PROJECT_PATH) && !File.directory?(PROJECT_PATH)
FileUtils.rm_rf(PROJECT_PATH) if File.directory?(PROJECT_PATH)

# ---- Info.plist ----
#
# We emit the plist from this script so the build settings stay the
# single source of truth. Can't use `GENERATE_INFOPLIST_FILE=YES`
# alongside a custom scheme because `CFBundleURLTypes` is an
# array-of-dicts and the `INFOPLIST_KEY_*` build-setting escape-hatch
# only supports scalar keys.
def write_info_plist(path)
  plist = {
    'CFBundleDevelopmentRegion'       => '$(DEVELOPMENT_LANGUAGE)',
    'CFBundleDisplayName'             => 'todarchy',
    'CFBundleExecutable'              => '$(EXECUTABLE_NAME)',
    'CFBundleIdentifier'              => '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CFBundleInfoDictionaryVersion'   => '6.0',
    'CFBundleName'                    => '$(PRODUCT_NAME)',
    'CFBundlePackageType'             => '$(PRODUCT_BUNDLE_PACKAGE_TYPE)',
    'CFBundleShortVersionString'      => '$(MARKETING_VERSION)',
    'CFBundleVersion'                 => '$(CURRENT_PROJECT_VERSION)',
    'LSApplicationCategoryType'       => 'public.app-category.productivity',
    'NSHumanReadableCopyright'        => 'Copyright 2026 todarchy',
    # Export compliance: app uses only standard Apple-framework crypto
    # (HTTPS, Speech). Declaring `false` skips the App Store Connect
    # export-compliance form on every TestFlight upload.
    'ITSAppUsesNonExemptEncryption'   => false,
    'NSMainStoryboardFile'            => '',
    'NSPrincipalClass'                => 'NSApplication',
    # Voice task capture (Apple Speech framework, on-device).
    'NSMicrophoneUsageDescription'    => 'todarchy uses the microphone so you can add tasks by speaking.',
    'NSSpeechRecognitionUsageDescription' => 'todarchy transcribes your voice on-device to turn it into a task. Audio never leaves your device.',
    # UI orientation + appearance.
    'UIStatusBarStyle'                => 'UIStatusBarStyleLightContent',
    'UIUserInterfaceStyle'            => 'Dark',
    'UISupportedInterfaceOrientations~iphone' => [
      'UIInterfaceOrientationPortrait'
    ],
    'UISupportedInterfaceOrientations~ipad' => [
      'UIInterfaceOrientationPortrait',
      'UIInterfaceOrientationPortraitUpsideDown',
      'UIInterfaceOrientationLandscapeLeft',
      'UIInterfaceOrientationLandscapeRight',
    ],
    # Auto-generated scene + launch shells (empty dicts produce the
    # same effect as GENERATE_INFOPLIST_FILE's *_Generation keys).
    'UIApplicationSceneManifest' => {
      'UIApplicationSupportsMultipleScenes' => true,
    },
    'UILaunchScreen'                  => {},
    # Custom URL scheme for share-link handoff:
    #   todarchy://share/<projectId>#k=<base64url-key>
    # Registered here so the OS routes matching URLs to `onOpenURL`.
    'CFBundleURLTypes' => [
      {
        'CFBundleURLName'   => 'com.todarchy.app.share',
        'CFBundleURLSchemes' => ['todarchy'],
        'CFBundleTypeRole'  => 'Editor',
      },
    ],
  }
  Xcodeproj::Plist.write_to_path(plist, path)
end

write_info_plist(INFO_PLIST_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastSwiftUpdateCheck'] = '1600'
project.root_object.attributes['LastUpgradeCheck'] = '1600'

# ---- Target ----
target = project.new_target(:application, 'todarchy', :ios, '17.0', nil, :swift)
target.product_name = 'todarchy'

# Add sources group
app_group = project.new_group('todarchy', 'todarchy')

# Walk the todarchy/ directory, add all .swift files and Resources + Assets
def add_files_recursive(group, dir, project, target, skip_resources: false)
  Dir.entries(dir).sort.each do |entry|
    next if entry.start_with?('.')
    path = File.join(dir, entry)
    if File.directory?(path)
      if entry == 'Assets.xcassets' || entry == 'Resources'
        # Add these specially; handled outside
        next
      end
      sub_group = group.new_group(entry, entry)
      add_files_recursive(sub_group, path, project, target)
    elsif entry.end_with?('.swift')
      file_ref = group.new_file(entry)
      target.source_build_phase.add_file_reference(file_ref)
    end
  end
end

add_files_recursive(app_group, APP_DIR, project, target)

# Add Assets.xcassets
assets_ref = app_group.new_file('Assets.xcassets')
target.resources_build_phase.add_file_reference(assets_ref)

# Add font files
res_group = app_group.new_group('Resources', 'Resources')
Dir.glob(File.join(APP_DIR, 'Resources', '*.ttf')).sort.each do |font_path|
  font_ref = res_group.new_file(File.basename(font_path))
  target.resources_build_phase.add_file_reference(font_ref)
end

# ---- Build settings ----
BUNDLE_ID = 'com.todarchy.app'

common = {
  'PRODUCT_NAME' => 'todarchy',
  'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ID,
  'SWIFT_VERSION' => '5.10',
  'CLANG_ENABLE_MODULES' => 'YES',
  'ENABLE_PREVIEWS' => 'YES',
  'CURRENT_PROJECT_VERSION' => '1',
  'MARKETING_VERSION' => '0.1',
  'DEVELOPMENT_TEAM' => '',
  'CODE_SIGN_STYLE' => 'Automatic',
  # Leave CODE_SIGN_IDENTITY unset so automatic signing can pick the
  # right identity per-platform (Apple Development for Debug, Apple
  # Distribution for Release/archive). Setting it to "-" forces ad-hoc
  # everywhere; setting `[sdk=iphoneos*]` to "" actively suppresses
  # iOS signing — both broke archive uploads to TestFlight.
  'SDKROOT' => 'auto',
  'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator macosx',
  'TARGETED_DEVICE_FAMILY' => '1,2',
  'IPHONEOS_DEPLOYMENT_TARGET' => '17.0',
  'MACOSX_DEPLOYMENT_TARGET' => '14.0',
  'SUPPORTS_MACCATALYST' => 'NO',
  'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
  'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
  'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
  'ENABLE_HARDENED_RUNTIME' => 'YES',
  # Tests keep auto-generation; the app overrides with INFOPLIST_FILE
  # below since a hand-written plist is required to register the
  # custom URL scheme (CFBundleURLTypes is array-of-dicts, which
  # INFOPLIST_KEY_* can't express).
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'COMBINE_HIDPI_IMAGES' => 'YES',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
  'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks @loader_path/Frameworks',
  'LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]' => '$(inherited) @executable_path/../Frameworks',
}

target.build_configurations.each do |config|
  config.build_settings.merge!(common)
  # App target: use the hand-written plist instead of auto-generation.
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  config.build_settings['INFOPLIST_FILE'] = 'todarchy/Info.plist'
  # Mac App Store requires App Sandbox. iOS ships without an
  # entitlements file (none of our iOS-side capabilities require one
  # today). The `[sdk=macosx*]` scope keeps the iOS build unchanged.
  config.build_settings['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]'] = 'todarchy/macOS/todarchy.entitlements'
end

# Release-only optimizations
target.build_configurations.find { |c| c.name == 'Release' }.build_settings.merge!({
  'SWIFT_OPTIMIZATION_LEVEL' => '-O',
})
target.build_configurations.find { |c| c.name == 'Debug' }.build_settings.merge!({
  'SWIFT_OPTIMIZATION_LEVEL' => '-Onone',
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'DEBUG',
})

# Project-level settings
project.build_configurations.each do |config|
  config.build_settings.merge!({
    'ALWAYS_SEARCH_USER_PATHS' => 'NO',
    'CLANG_ANALYZER_NONNULL' => 'YES',
    'CLANG_ENABLE_OBJC_ARC' => 'YES',
    'CLANG_WARN_DOCUMENTATION_COMMENTS' => 'YES',
    'COPY_PHASE_STRIP' => 'NO',
    'ENABLE_STRICT_OBJC_MSGSEND' => 'YES',
    'GCC_C_LANGUAGE_STANDARD' => 'gnu17',
    'GCC_NO_COMMON_BLOCKS' => 'YES',
    'DEBUG_INFORMATION_FORMAT' => 'dwarf-with-dsym',
    'ENABLE_NS_ASSERTIONS' => 'NO',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
  })
end

# ---- automerge-swift SPM dependency ----
automerge_ref = project.root_object.package_references.find do |r|
  r.respond_to?(:repositoryURL) && r.repositoryURL == 'https://github.com/automerge/automerge-swift'
end

unless automerge_ref
  automerge_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  automerge_ref.repositoryURL = 'https://github.com/automerge/automerge-swift'
  automerge_ref.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '0.5.2' }
  project.root_object.package_references << automerge_ref
end

automerge_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
automerge_product.package = automerge_ref
automerge_product.product_name = 'Automerge'
target.package_product_dependencies << automerge_product

# Link Automerge into the build phase.
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = automerge_product
target.frameworks_build_phase.files << build_file

# ---- MarkdownUI SPM dependency ----
# Renders the task body's markdown as actual headings, lists, code
# blocks, etc. Native `AttributedString(markdown:)` only handles inline
# styling (bold/italic/links) — fine for short notes but not for the
# rich plans Claude writes via `set_task_body`.
markdownui_ref = project.root_object.package_references.find do |r|
  r.respond_to?(:repositoryURL) && r.repositoryURL == 'https://github.com/gonzalezreal/swift-markdown-ui'
end

unless markdownui_ref
  markdownui_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  markdownui_ref.repositoryURL = 'https://github.com/gonzalezreal/swift-markdown-ui'
  markdownui_ref.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '2.0.0' }
  project.root_object.package_references << markdownui_ref
end

markdownui_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
markdownui_product.package = markdownui_ref
markdownui_product.product_name = 'MarkdownUI'
target.package_product_dependencies << markdownui_product

markdownui_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
markdownui_build_file.product_ref = markdownui_product
target.frameworks_build_phase.files << markdownui_build_file

# ---- Local Argon2 SPM package ----
# Vendors libargon2 (reference impl) for passphrase-derived master-key
# derivation. Lives in `Packages/Argon2/`. Linked into both the app
# target and the test target so MasterKey + its tests can derive keys.
argon2_ref = project.root_object.package_references.find do |r|
  r.respond_to?(:relative_path) && r.relative_path == 'Packages/Argon2'
end

unless argon2_ref
  argon2_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  argon2_ref.relative_path = 'Packages/Argon2'
  project.root_object.package_references << argon2_ref
end

argon2_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
argon2_product.package = argon2_ref
argon2_product.product_name = 'Argon2'
target.package_product_dependencies << argon2_product

argon2_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
argon2_build_file.product_ref = argon2_product
target.frameworks_build_phase.files << argon2_build_file

# ---- Test target ----
test_target = project.new_target(:unit_test_bundle, 'todarchyTests', :osx, '14.0', nil, :swift)

tests_dir = File.join(ROOT, 'todarchyTests')
tests_group = project.new_group('todarchyTests', 'todarchyTests')
Dir.entries(tests_dir).sort.each do |entry|
  next unless entry.end_with?('.swift')
  fr = tests_group.new_file(entry)
  test_target.source_build_phase.add_file_reference(fr)
end

# Compile app sources into the test bundle too — skip todarchyApp.swift so
# the test bundle has no @main (it's a plain xctest bundle loaded by XCTest).
# This avoids the SwiftUI-App-vs-XCTest NSApplication conflict and keeps the
# test target independent of the host app binary.
def collect_app_sources(dir, skip_basenames: [])
  result = []
  Dir.entries(dir).sort.each do |entry|
    next if entry.start_with?('.')
    path = File.join(dir, entry)
    if File.directory?(path)
      next if entry == 'Assets.xcassets' || entry == 'Resources'
      result.concat(collect_app_sources(path, skip_basenames: skip_basenames))
    elsif entry.end_with?('.swift') && !skip_basenames.include?(entry)
      result << path
    end
  end
  result
end

app_sources_for_tests = collect_app_sources(APP_DIR, skip_basenames: ['todarchyApp.swift'])
app_sources_for_tests.each do |src|
  file_ref = project.main_group.new_file(src)
  test_target.source_build_phase.add_file_reference(file_ref)
end

# Pull selected MCP-target sources into the test bundle so we can
# exercise their integration with the shared data layer. Currently
# just `TodarchyDoc.swift` so we can regression-test its
# merge-with-disk behavior on save.
mcp_sources_for_tests = ['TodarchyDoc.swift'].map { |b| File.join(ROOT, 'todarchy-mcp', b) }
mcp_sources_for_tests.each do |src|
  file_ref = project.main_group.new_file(src)
  test_target.source_build_phase.add_file_reference(file_ref)
end

test_common = common.dup
test_common['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.todarchy.app.tests'
test_common['PRODUCT_NAME'] = 'todarchyTests'
test_common['SUPPORTED_PLATFORMS'] = 'macosx'
test_common['SDKROOT'] = 'macosx'
test_common['FRAMEWORK_SEARCH_PATHS'] = '$(inherited) $(DEVELOPER_FRAMEWORKS_DIR)'
test_common['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks'
# Tests only need macOS. Plist keys that used to live in `common` now
# live in the hand-written todarchy/Info.plist, so there's nothing
# plist-related to delete from test_common any more.
test_common.delete('TARGETED_DEVICE_FAMILY')
test_common.delete('IPHONEOS_DEPLOYMENT_TARGET')
test_common.delete('SUPPORTS_MACCATALYST')
test_common.delete('SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD')
test_common.delete('CODE_SIGN_IDENTITY[sdk=iphoneos*]')
test_common.delete('ASSETCATALOG_COMPILER_APPICON_NAME')
test_common.delete('ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME')

test_target.build_configurations.each do |config|
  config.build_settings.merge!(test_common)
end

# Test target also links Automerge — test files import the framework.
test_automerge_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
test_automerge_product.package = automerge_ref
test_automerge_product.product_name = 'Automerge'
test_target.package_product_dependencies << test_automerge_product
test_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
test_build_file.product_ref = test_automerge_product
test_target.frameworks_build_phase.files << test_build_file

# Test target compiles the shared `MarkdownText.swift` from the app
# target, which imports `MarkdownUI` — so the test bundle has to link
# it too. Same one-off wiring as Automerge above.
test_markdownui_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
test_markdownui_product.package = markdownui_ref
test_markdownui_product.product_name = 'MarkdownUI'
test_target.package_product_dependencies << test_markdownui_product
test_markdownui_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
test_markdownui_build_file.product_ref = test_markdownui_product
test_target.frameworks_build_phase.files << test_markdownui_build_file

# Test target also links the local Argon2 package — MasterKey tests
# call `Argon2.deriveKey` directly to verify derivation behavior.
test_argon2_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
test_argon2_product.package = argon2_ref
test_argon2_product.product_name = 'Argon2'
test_target.package_product_dependencies << test_argon2_product
test_argon2_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
test_argon2_build_file.product_ref = test_argon2_product
test_target.frameworks_build_phase.files << test_argon2_build_file

# ---- MCP server target (macOS CLI binary, todarchy-mcp) ----
# Exposes a JSON-RPC stdio interface backed by `tasks.automerge`,
# scoped to projects whose `claudeAccess` flag is true. Sharing source
# with the app target (rather than extracting a TodarchyCore package)
# is intentional — same approach the test target uses; keeps the
# build system unchanged.
mcp_target = project.new_target(:command_line_tool, 'todarchy-mcp', :osx, '14.0', nil, :swift)
mcp_target.product_name = 'todarchy-mcp'

mcp_dir = File.join(ROOT, 'todarchy-mcp')
mcp_group = project.new_group('todarchy-mcp', 'todarchy-mcp')
Dir.entries(mcp_dir).sort.each do |entry|
  next unless entry.end_with?('.swift')
  fr = mcp_group.new_file(entry)
  mcp_target.source_build_phase.add_file_reference(fr)
end

# Pull the data-layer subset of the app target's sources into the MCP
# target. Skip everything UI-heavy (views, sheets, key routers) — the
# MCP server only needs to read/write the Automerge doc, so giving it
# the same minimum surface keeps build times small and the audit
# surface narrow.
MCP_SHARED_SOURCES = [
  'AutomergeStore.swift',
  'Models.swift',
  'Theme.swift',
  'Parser.swift',
  File.join('Shared', 'Snapshot.swift'),
]
MCP_SHARED_SOURCES.each do |src_name|
  src_path = File.join(APP_DIR, src_name)
  next unless File.exist?(src_path)
  file_ref = project.main_group.new_file(src_path)
  mcp_target.source_build_phase.add_file_reference(file_ref)
end

mcp_common = common.dup
mcp_common['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.todarchy.mcp'
mcp_common['PRODUCT_NAME'] = 'todarchy-mcp'
mcp_common['SUPPORTED_PLATFORMS'] = 'macosx'
mcp_common['SDKROOT'] = 'macosx'
mcp_common.delete('TARGETED_DEVICE_FAMILY')
mcp_common.delete('IPHONEOS_DEPLOYMENT_TARGET')
mcp_common.delete('SUPPORTS_MACCATALYST')
mcp_common.delete('SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD')
mcp_common.delete('CODE_SIGN_IDENTITY[sdk=iphoneos*]')
mcp_common.delete('ASSETCATALOG_COMPILER_APPICON_NAME')
mcp_common.delete('ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME')
mcp_target.build_configurations.each do |config|
  config.build_settings.merge!(mcp_common)
end

# Link Automerge into the MCP target too — same package reference,
# new product dependency.
mcp_automerge_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
mcp_automerge_product.package = automerge_ref
mcp_automerge_product.product_name = 'Automerge'
mcp_target.package_product_dependencies << mcp_automerge_product
mcp_automerge_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
mcp_automerge_build_file.product_ref = mcp_automerge_product
mcp_target.frameworks_build_phase.files << mcp_automerge_build_file

# Save scheme that includes tests
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(test_target)
scheme.set_launch_target(target)
scheme.save_as(PROJECT_PATH, 'todarchy', true)

# Dedicated scheme for the MCP CLI. Building it directly is what the
# install step does (`xcodebuild -scheme todarchy-mcp -configuration
# Release build`), and having a scheme is what ensures the Automerge
# package gets built as a dependency before the MCP target is linked.
mcp_scheme = Xcodeproj::XCScheme.new
mcp_scheme.add_build_target(mcp_target)
mcp_scheme.set_launch_target(mcp_target)
mcp_scheme.save_as(PROJECT_PATH, 'todarchy-mcp', true)

puts "Project generated at #{PROJECT_PATH}"
