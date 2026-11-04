Pod::Spec.new do |s|
  s.name             = 'sip_helper'
  s.version          = '0.4.0'
  s.summary          = 'SIP/VoIP for Flutter with native call audio.'
  s.description      = <<-DESC
SIP over UDP, RTP and G.711 with native call audio (AVAudioEngine with voice
processing) for Flutter apps.
                       DESC
  s.homepage         = 'https://github.com/orestislef/sip_helper'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'orestislef'
  s.source           = { :path => '.' }
  s.source_files     = 'sip_helper/Sources/sip_helper/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.frameworks = 'AVFoundation'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
