# DocScan's C++ engine for iOS. Sources are shared with Android through forwarders in Classes/.
# OpenCV comes from the prebuilt opencv2.framework (scripts/fetch_opencv.sh ios).
Pod::Spec.new do |s|
  s.name             = 'docscan_engine'
  s.version          = '1.0.0'
  s.summary          = 'Native C++ document scanning engine.'
  s.description      = 'Document detection, perspective correction, page straightening and filters, built on OpenCV.'
  s.homepage         = 'https://github.com/'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'DocScan' => 'dev@docscan.dev' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/docscan.h'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  s.vendored_frameworks = 'opencv2.framework'
  s.frameworks = 'Accelerate', 'AVFoundation', 'CoreGraphics', 'CoreImage', 'CoreMedia', 'CoreVideo',
                 'Foundation', 'QuartzCore', 'UIKit'
  s.libraries = 'c++', 'z'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'GCC_OPTIMIZATION_LEVEL' => '3',
    # The prebuilt OpenCV framework ships device arm64 and simulator x86_64 slices
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64 i386',
  }
  s.user_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64 i386' }
end
