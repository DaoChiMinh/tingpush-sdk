Pod::Spec.new do |s|
  s.name             = 'tingpush'
  s.version          = '1.1.0'
  s.summary          = 'SDK Flutter cho TingPush: nhận cuộc gọi VoIP (PushKit + CallKit).'
  s.homepage         = 'https://tingpush.com'
  s.license          = { :type => 'Proprietary', :text => 'Copyright TingPush' }
  s.author           = { 'TingPush' => 'support@tingpush.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'tingpush/Sources/tingpush/**/*.swift'
  s.dependency 'Flutter'
  s.dependency 'flutter_callkit_incoming'
  s.platform = :ios, '15.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
