source 'https://github.com/CocoaPods/Specs.git'
platform :osx, '11.0'

target 'V2rayU' do
  use_frameworks!

  # limm VPN fork — Firebase and AppCenter removed
  pod 'SwiftyJSON'
  pod 'Preferences', :git => 'https://github.com/sindresorhus/Settings.git', :tag => 'v2.6.0'
  pod 'QRCoder'
  pod 'MASShortcut'
  pod 'Swifter'
  pod 'Yams'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '11.0'
    end
  end
end
