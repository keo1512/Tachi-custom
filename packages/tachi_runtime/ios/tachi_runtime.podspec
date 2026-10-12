Pod::Spec.new do |s|
  s.name = 'tachi_runtime'
  s.version = '0.1.0'
  s.summary = 'Interpreted APK source execution inside the iOS app.'
  s.homepage = 'https://github.com/smilenek/Tachi-custom'
  s.license = { :type => 'Private' }
  s.author = { 'TachiBooks' => 'TachiBooks' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,m}'
  s.dependency 'Flutter'
  s.frameworks = 'WebKit'
  s.platform = :ios, '15.0'
  s.resource_bundles = {
    'TachiRuntime' => ['Runtime/jre', 'Runtime/engine', 'Runtime/licenses']
  }
  s.preserve_paths = 'Runtime/include/**/*'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/Runtime/include" "$(PODS_TARGET_SRCROOT)/Runtime/include/darwin"',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
