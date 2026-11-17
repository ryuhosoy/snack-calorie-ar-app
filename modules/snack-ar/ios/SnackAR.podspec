Pod::Spec.new do |s|
  s.name           = 'SnackAR'
  s.version        = '1.0.0'
  s.summary        = 'お菓子のカロリーをARで表示するネイティブモジュール'
  s.description    = 'ARKit + Vision + SQLite(FTS5) によるお菓子カロリーAR'
  s.license        = 'MIT'
  s.author         = 'snack-calorie-ar'
  s.homepage       = 'https://example.com/snack-calorie-ar'
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.source_files = '**/*.{h,m,swift}'
  # snacks.sqlite（と、あれば学習済みの SnackDetector.mlmodelc）を同梱
  s.resource_bundles = { 'SnackARResources' => ['Resources/**/*'] }
  s.frameworks = 'ARKit', 'SceneKit', 'Vision', 'CoreML'
  s.libraries = 'sqlite3'
end
