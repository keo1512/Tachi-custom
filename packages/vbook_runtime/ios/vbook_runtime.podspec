Pod::Spec.new do |s|
  s.name = 'vbook_runtime'
  s.version = '0.1.0'
  s.summary = 'JavaScriptCore vBook extension host for TachiBooks.'
  s.description = 'Original on-device synchronous HTTP and HTML host for plaintext extension scripts.'
  s.homepage = 'https://github.com/smilenek/Tachi-custom'
  s.license = { :type => 'MIT', :file => '../LICENSE' }
  s.author = { 'TachiBooks' => 'TachiBooks' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'
  s.resource_bundles = { 'VbookRuntime' => ['Resources/*.js', 'Resources/*.LICENSE', 'Resources/*.provenance.json'] }
  s.dependency 'Flutter'
  s.dependency 'SwiftSoup', '2.11.3'
  s.frameworks = 'JavaScriptCore', 'Security', 'CryptoKit'
  s.platform = :ios, '15.0'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
