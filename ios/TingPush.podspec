Pod::Spec.new do |s|
  s.name             = 'TingPush'
  s.version          = '1.1.1'
  s.summary          = 'SDK iOS cho TingPush: đăng ký thiết bị, thông báo, cuộc gọi CallKit qua VoIP push.'
  s.homepage         = 'https://example.com/tingpush'
  s.license          = { :type => 'Proprietary' }
  s.author           = 'TingPush'
  # Đổi thành repo git nội bộ của bạn, hoặc dùng :path => trong Podfile.
  s.source           = { :git => 'https://example.com/tingpush-sdk.git', :tag => s.version.to_s }
  s.ios.deployment_target = '13.0'
  s.swift_version    = '5.7'
  s.source_files     = 'Sources/TingPush/**/*.swift'
  s.frameworks       = 'UIKit', 'UserNotifications', 'PushKit', 'CallKit', 'AVFoundation'
end
