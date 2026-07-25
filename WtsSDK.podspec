Pod::Spec.new do |s|
  s.name = 'WtsSDK'
  s.version = '0.5.0-alpha.2'
  s.summary = 'Official wts.is deep-link, analytics, identity and Experiences SDK.'
  s.homepage = 'https://wts.is'
  s.license = { :type => 'Apache-2.0' }
  s.author = { 'Wetus' => 'info@wetus.co' }
  s.source = { :git => 'https://github.com/wetuscorp/wtsissdk-swift.git', :tag => "#{s.version}" }
  s.source_files = 'Sources/WtsSDK/**/*.swift'
  s.resource_bundles = { 'WtsSDKPrivacy' => ['Sources/WtsSDK/Resources/PrivacyInfo.xcprivacy'] }
  s.platform = :ios, '15.0'
  s.swift_version = '5.9'
end
