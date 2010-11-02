require './lib/svt/recorder'

Gem::Specification.new do |s|
  s.name = 'svt-recorder'
  s.version = SVT::Recorder::VERSION
  s.description = 'A program that helps you record videos from SVTPlay.se and PlayRapport.se'
  s.authors = ['Björn Andersson']
  s.email = 'ba@sanitarium.se'
  s.homepage = 'http://github.com/gaqzi/svt-recorder'
  s.summary = s.description
  s.files = ['README'] \
               + Dir.glob('lib/svt/**/*.rb') \
               + Dir.glob('spec/*.rb') \
               + Dir.glob('spec/support/*')
  s.test_files = Dir.glob('spec/*_spec.rb')
  s.executables << 'svt-recorder'
  s.has_rdoc = true
  s.extra_rdoc_files = ['README']
  s.rdoc_options << '-x spec --main lib/svt/recorder.rb --line-numbers'
  s.add_development_dependency('rspec', '>= 2.0.0')
end
