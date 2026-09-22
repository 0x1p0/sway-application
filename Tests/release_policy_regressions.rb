require 'yaml'
require 'rexml/document'

root = File.expand_path('..', __dir__)
release = YAML.load_file(File.join(root, '.github/workflows/release.yml'))
checks = YAML.load_file(File.join(root, '.github/workflows/checks.yml'))
count = 0
expect = lambda do |condition, message|
  abort("Release policy failed: #{message}") unless condition
  count += 1
end
build = release.fetch('jobs').fetch('build')
sign = release.fetch('jobs').fetch('release')
expect.call(release.fetch('permissions') == {'contents' => 'read'}, 'read-only workflow default')
expect.call(build.fetch('permissions') == {'contents' => 'read'}, 'build must not write to repository')
expect.call(!build.key?('environment') && !build.to_s.include?('secrets.'), 'build must have no protected environment or secrets')
expect.call(sign.fetch('needs') == 'build', 'signing requires successful build')
expect.call(sign.fetch('environment').fetch('name') == 'release', 'release approval environment required')
steps = sign.fetch('steps')
checkout = steps.find { |step| step['uses'].to_s.start_with?('actions/checkout@') }
expect.call(checkout.fetch('with').fetch('ref') == 'main', 'signing tools must come from protected main')
expect.call(checkout.fetch('with').fetch('persist-credentials') == false, 'do not persist repository credentials')
expect.call(steps.any? { |step| step['run'].to_s.include?('test "$(git rev-parse HEAD)" = "$GITHUB_SHA"') }, 'release source must equal protected main')
download = steps.find { |step| step['uses'].to_s.start_with?('actions/download-artifact@') }
expect.call(download.fetch('with').fetch('artifact-ids') == '${{ needs.build.outputs.artifact-id }}', 'download exact artifact ID from this build')
expect.call(download.fetch('with').fetch('path') == '${{ runner.temp }}/sway-release', 'artifacts must not overwrite signing sources or executables')
expect.call(download.fetch('with').fetch('digest-mismatch') == 'error', 'artifact integrity failures must stop the release')
secret_steps = steps.select { |step| step.fetch('env', {}).key?('SPARKLE_PRIVATE_KEY') }
expect.call(secret_steps.length == 1, 'only one step receives the signing key')
expect.call(secret_steps.first.fetch('run').include?('"$RUNNER_TEMP/sway-sign-update"'), 'invoke the precompiled signer')
expect.call(secret_steps.first.fetch('run') !~ /xcrun|swiftc|pip|bash|unzip|ditto|curl/, 'do not build, download, or unpack while holding the key')
expect.call(steps.map { |step| step['run'] }.join("\n") !~ /generate_appcast|package-release|setup-sparkle|setup-dmg|test-updater|pip install/, 'signing runner must not run build dependencies or downloaded apps')
expect.call(sign.fetch('permissions') == {'contents' => 'write'}, 'release job gets only publishing permissions')
events = checks['on'] || checks[true] # YAML 1.1 treats "on" as a boolean.
expect.call(events.key?('pull_request') && !events.key?('pull_request_target'), 'PR checks must be unprivileged')
expect.call(checks.fetch('permissions') == {'contents' => 'read'}, 'PR token must be read-only')
expect.call(checks.fetch('jobs').fetch('checks').fetch('name') == 'Sway checks', 'required status-check name must stay stable')
expect.call(!checks.to_s.include?('secrets.'), 'PR checks must never reference secrets')
[release, checks].each do |workflow|
  workflow.fetch('jobs').each_value do |job|
    job.fetch('steps').each do |step|
      next unless step['uses']
      expect.call(step['uses'].match?(/\Aactions\/[a-z-]+@[0-9a-f]{40}\z/), 'actions must be pinned to official immutable commits')
    end
  end
end
entitlements = REXML::Document.new(File.read(File.join(root, 'Sway/Sway.entitlements')))
keys = REXML::XPath.match(entitlements, '//key').map(&:text)
expect.call(keys == ['com.apple.security.cs.disable-library-validation'], 'only the required ad-hoc exception is allowed')
build_script = File.read(File.join(root, 'scripts/build.sh'))
expect.call(build_script.include?('--options runtime') && build_script.include?('scripts/verify-runtime.sh'), 'runtime must be enabled and checked in release builds')
signer = File.read(File.join(root, 'scripts/sign-update.swift'))
expect.call(!signer.include?('Process(') && !signer.include?('Bundle('), 'signer must not execute or load artifact code')
puts "#{count} release-security policy assertions passed."
