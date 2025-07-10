require_relative 'lib/oss_stats/version'

Gem::Specification.new do |spec|
  spec.name = 'oss-stats'
  spec.version = OssStats::VERSION
  spec.summary = 'Suite of tools for reporting health of F/OSS communities'
  spec.authors = ['Phil Dibowitz']
  spec.email = ['phil@ipom.com']
  spec.license = 'Apache-2.0'
  spec.homepage = 'https://github.com/jaymzh/oss-stats'
  spec.required_ruby_version = '>= 3.2'
  docs = %w{
    README.md
    LICENSE
    Gemfile
    oss-stats.gemspec
    CONTRIBUTING.md
    CHANGELOG.md
  } + Dir.glob('examples/*') | Dir.glob('docs/*')
  spec.extra_rdoc_files = docs
  spec.executables += Dir.glob('bin/*').map { |x| File.basename(x) }
  spec.files =
    Dir.glob('lib/oss_stats/*.rb') +
    Dir.glob('lib/oss_stats/config/*.rb') +
    Dir.glob('bin/*') +
    Dir.glob('extras/*') +
    Dir.glob('spec/*') +
    Dir.glob('scripts/*') +
    Dir.glob('initialization_data/*') +
    Dir.glob('initialization_data/github_workflow/s*')
  %w{
    base64
    deep_merge
    faraday-retry
    gruff
    mixlib-config
    mixlib-log
    octokit
    sqlite3
  }.each do |dep|
    spec.add_dependency dep
  end
  spec.metadata = {
    'rubygems_mfa_required' => 'true',
    'bug_tracker_uri' => 'https://github.com/jaymzh/oss-stats/issues',
    'homepage_uri' => 'https://github.com/jaymzh/oss-stats',
    'source_code_uri' => 'https://github.com/jaymzh/oss-stats',
  }
end
