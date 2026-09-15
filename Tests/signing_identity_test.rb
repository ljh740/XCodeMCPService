require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require_relative '../scripts/signing_identity'

class SigningIdentityTest < Minitest::Test
  FINGERPRINT = 'A' * 40

  def setup
    @now = Time.utc(2026, 9, 14)
    @key = OpenSSL::PKey::RSA.new(1024)
  end

  def certificate(name: 'Apple Development: Test (PERSON1234)', team: 'TEAM123456',
                  issuer: 'Apple Inc.', organization: 'Fixture Team',
                  expires: @now + 86_400, starts: @now - 86_400)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.new([['CN', name], ['OU', team], ['O', organization]])
    cert.issuer = issuer == :self ? cert.subject : OpenSSL::X509::Name.new([['O', issuer]])
    cert.public_key = @key.public_key
    cert.not_before = starts
    cert.not_after = expires
    cert.sign(@key, OpenSSL::Digest::SHA256.new)
    cert
  end

  def identity(cert, suffix = '')
    hash = OpenSSL::Digest::SHA1.hexdigest(cert.to_der).upcase
    "  1) #{hash} \"#{cert.subject.to_a.assoc('CN')[1]}\"#{suffix}\n"
  end

  def select(certs, identities: certs.map { |cert| identity(cert) }.join, permissions: {})
    SigningIdentity.select(identities, certs.map(&:to_pem).join, permissions, now: @now)
  end

  def permissions(*teams, identifier: SigningIdentity::APP_IDENTIFIER, expiration: nil)
    { 'permission' => { 'permittedAgents' => teams.map do |team|
      { 'trust' => { 'signed' => { 'teamIdentifier' => team,
                                 'signingIdentifier' => identifier,
                                 'expiration' => expiration } } }
    end } }
  end

  def discovery(certs, status: '{}', failure: nil)
    calls = []
    command = lambda do |*args|
      calls << args
      case args[1]
      when 'find-identity' then certs.map { |cert| identity(cert) }.join
      when 'find-certificate' then certs.map(&:to_pem).join
      when '--find'
        raise failure if failure
        '/mock/mcp-server'
      else status
      end
    end
    output = SigningIdentity.stub(:capture, command) do
      Time.stub(:now, @now) { capture_io { SigningIdentity.run } }
    end
    [*output, calls]
  end

  def build_configuration(ruby_stub: '', env: {}, command: nil)
    script = File.expand_path('../build-app.sh', __dir__)
    prefix = File.read(script).split('echo "=== Building XCodeMCPService ==="').first
    command ||= "printf '%s|%s' \"$CODE_SIGN_IDENTITY\" \"$CODE_SIGN_TIMESTAMP\""
    Open3.capture3(
      { 'CODE_SIGN_IDENTITY' => nil, 'CODE_SIGN_TIMESTAMP' => nil }.merge(env),
      '/bin/bash', '-c', ruby_stub + "\n" + prefix + "\n" + command, script
    )
  end

  def test_existing_grant_uses_certificate_ou_not_name_suffix
    preferred = certificate(team: 'OLDTEAM123')
    other = certificate(expires: @now + 172_800)
    permissions = { 'permission' => { 'permittedAgents' => [
      { 'trust' => { 'signed' => { 'teamIdentifier' => 'OLDTEAM123',
                                 'signingIdentifier' => SigningIdentity::APP_IDENTIFIER } } }
    ] } }
    assert_equal 'OLDTEAM123', select([other, preferred], permissions: permissions)[:team]
  end

  def test_revoked_identity_is_excluded_even_in_valid_identity_output
    cert = certificate
    assert_nil select([cert], identities: identity(cert, ' (CSSMERR_TP_CERT_REVOKED)'))
  end

  def test_certificate_without_private_key_identity_is_excluded
    assert_nil select([certificate], identities: '')
  end

  def test_expired_and_future_certificates_are_excluded
    assert_nil select([certificate(expires: @now)])
    assert_nil select([certificate(starts: @now + 1)])
  end

  def test_self_signed_and_distribution_certificates_are_excluded
    assert_nil select([certificate(issuer: 'Local Signing')])
    assert_nil select([certificate(name: 'Apple Distribution: Company')])
    assert_nil select([certificate(team: '')])
    assert_nil select([certificate(issuer: :self, organization: 'Apple Inc.')])
  end

  def test_multiple_teams_without_a_unique_authorized_match_are_not_selected
    certs = [certificate, certificate(team: 'OTHER12345')]
    [{}, permissions('TEAM123456', 'OTHER12345'), permissions('ABSENT1234')].each do |grants|
      _, error = capture_io { assert_nil select(certs, permissions: grants) }
      assert_includes error, 'Multiple eligible signing teams'
      assert_includes error, 'CODE_SIGN_IDENTITY'
    end
  end

  def test_duplicate_grants_for_one_candidate_team_are_not_ambiguous
    certs = [certificate, certificate(team: 'OTHER12345')]
    grants = permissions('TEAM123456', 'TEAM123456', 'ABSENT1234')
    assert_equal 'TEAM123456', select(certs, permissions: grants)[:team]
  end

  def test_unrelated_and_expired_grants_cannot_break_a_team_tie
    certs = [certificate, certificate(team: 'OTHER12345')]
    [permissions('TEAM123456', identifier: 'other.app'),
     permissions('TEAM123456', expiration: @now.to_i - SigningIdentity::APPLE_REFERENCE_DATE),
     permissions('TEAM123456', expiration: 'invalid')].each do |grants|
      capture_io { assert_nil select(certs, permissions: grants) }
    end
  end

  def test_unexpired_temporary_grant_can_break_a_team_tie
    certs = [certificate, certificate(team: 'OTHER12345')]
    grants = permissions('OTHER12345', expiration: @now.to_i - SigningIdentity::APPLE_REFERENCE_DATE + 1)
    assert_equal 'OTHER12345', select(certs, permissions: grants)[:team]
  end

  def test_malformed_optional_permissions_do_not_block_a_unique_team
    [nil, [], { 'permission' => nil }, { 'permission' => { 'permittedAgents' => 'invalid' } },
     { 'permission' => { 'permittedAgents' => [nil, {}, { 'trust' => { 'signed' => false } }] } }].each do |grants|
      assert_equal 'TEAM123456', select([certificate], permissions: grants)[:team]
    end
  end

  def test_malformed_certificate_does_not_hide_other_valid_certificates
    cert = certificate
    malformed = "-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----\n"
    _, error = capture_io do
      result = SigningIdentity.select(identity(cert), malformed + cert.to_pem, {}, now: @now)
      assert_equal 'TEAM123456', result[:team]
    end
    assert_includes error, 'malformed Keychain certificate'
  end

  def test_certificates_from_multiple_keychains_match_by_fingerprint
    first = certificate(team: 'OTHER12345')
    usable = certificate
    result = select([first, usable, usable], identities: identity(usable).downcase)
    assert_equal 'TEAM123456', result[:team]
  end

  def test_same_team_ties_are_deterministic_and_legacy_mac_developer_is_supported
    first = certificate(name: 'Mac Developer: Fixture')
    second = certificate(name: 'Apple Development: Other Fixture')
    assert_equal select([first, second]), select([second, first])
    assert_equal 'Mac Developer: Fixture', select([first])[:name]
  end

  def test_development_preferred_for_local_build_and_newest_expiry_breaks_tie
    distribution = certificate(name: 'Developer ID Application: Company')
    development = certificate(expires: @now + 172_800)
    result = select([distribution, certificate, development])
    assert_equal development.not_after, result[:expires]
    assert result[:name].start_with?('Apple Development:')
  end

  def test_empty_keychain_falls_back_without_candidate
    assert_nil select([])
  end

  def test_absent_mcp_server_still_allows_a_unique_team
    cert = certificate
    output, error, calls = discovery([cert], failure: 'mcp-server unavailable')
    assert_equal "#{OpenSSL::Digest::SHA1.hexdigest(cert.to_der).upcase}\nnone\n", output
    assert_includes error, 'mcp-server unavailable'
    assert_includes calls, ['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning']
    assert_includes calls, ['/usr/bin/security', 'find-certificate', '-a', '-p']
  end

  def test_unavailable_permissions_leave_multiple_teams_ambiguous
    certs = [certificate, certificate(team: 'OTHER12345')]
    output, error, = discovery(certs, failure: 'mcp-server unavailable')
    assert_equal "-\nauto\n", output
    assert_includes error, 'Multiple eligible signing teams'
  end

  def test_invalid_status_json_is_optional
    output, error, = discovery([certificate], status: 'invalid JSON')
    assert_match(/\A[A-F0-9]{40}\nnone\n\z/, output)
    assert_includes error, 'Existing Xcode signing preference unavailable'
  end

  def test_empty_ci_keychain_preserves_ad_hoc_signing
    output, = discovery([])
    assert_equal "-\nauto\n", output
  end

  def test_capture_passes_arguments_without_shell_interpolation
    argument = 'spaces ; $(exit 9)'
    assert_equal argument, SigningIdentity.capture(RbConfig.ruby, '-e', 'print ARGV.first', argument)
  end

  def test_capture_reports_command_failure
    assert_raises(RuntimeError) { SigningIdentity.capture(RbConfig.ruby, '-e', 'print "partial"; exit 3') }
    assert_raises(Errno::ENOENT) { SigningIdentity.capture('/no-such-signing-test-command') }
  end

  def test_capture_bounds_both_output_read_and_exit_wait
    ['sleep 5', 'STDOUT.close; sleep 5'].each do |program|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Timeout::Error) { SigningIdentity.capture(RbConfig.ruby, '-e', program, timeout: 0.1) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    end
  end

  def test_discovery_output_uses_fingerprint_and_development_timestamp
    cert = certificate
    command = lambda do |*args|
      case args[1]
      when 'find-identity' then identity(cert)
      when 'find-certificate' then cert.to_pem
      when '--find' then '/mock/mcp-server'
      else '{}'
      end
    end
    SigningIdentity.stub(:capture, command) do
      SigningIdentity.stub(:select, { fingerprint: 'ABC', name: 'Apple Development: Test', team: 'TEAM123456' }) do
        output, = capture_io { SigningIdentity.run }
        assert_equal "ABC\nnone\n", output
      end
    end
  end

  def test_discovery_failure_preserves_ad_hoc_fallback
    SigningIdentity.stub(:capture, ->(*) { raise 'Keychain unavailable' }) do
      output, error = capture_io { SigningIdentity.run }
      assert_equal "-\nauto\n", output
      assert_includes error, 'Keychain unavailable'
    end
  end

  def test_developer_id_keeps_secure_timestamp_default
    SigningIdentity.stub(:capture, '{}') do
      SigningIdentity.stub(:select, { fingerprint: 'ABC', name: 'Developer ID Application: Test', team: 'TEAM123456' }) do
        output, = capture_io { SigningIdentity.run }
        assert_equal "ABC\nauto\n", output
      end
    end
  end

  def test_no_candidate_preserves_ad_hoc_fallback
    SigningIdentity.stub(:capture, '{}') do
      SigningIdentity.stub(:select, nil) do
        output, = capture_io { SigningIdentity.run }
        assert_equal "-\nauto\n", output
      end
    end
  end

  def test_build_consumes_auto_selection_and_preserves_timestamp_override
    [nil, 'secure'].each do |timestamp|
      output, error, status = build_configuration(
        env: { 'CODE_SIGN_TIMESTAMP' => timestamp },
        ruby_stub: "ruby() { printf '#{FINGERPRINT}\\nnone\\n'; }"
      )
      assert status.success?, error
      assert_equal "#{FINGERPRINT}|#{timestamp || 'none'}", output
    end
  end

  def test_explicit_identity_and_timestamp_are_not_overridden
    ['-', 'EXPLICIT_CERTIFICATE', 'Apple Development: Fixture (USER123456)'].each do |identity|
      output, error, status = build_configuration(
        env: { 'CODE_SIGN_IDENTITY' => identity, 'CODE_SIGN_TIMESTAMP' => 'secure' },
        ruby_stub: 'ruby() { echo "must not run" >&2; return 99; }'
      )
      assert status.success?, error
      assert_equal "#{identity}|secure", output
      refute_includes error, 'must not run'
    end
  end

  def test_explicit_identity_preserves_original_timestamp_default
    output, error, status = build_configuration(env: { 'CODE_SIGN_IDENTITY' => 'EXPLICIT_CERTIFICATE' })
    assert status.success?, error
    assert_equal 'EXPLICIT_CERTIFICATE|auto', output
  end

  def test_missing_ruby_and_dependency_load_failure_preserve_build_fallback
    stubs = [
      'command() { if [ "$1" = "-v" ] && [ "$2" = "ruby" ]; then return 1; fi; builtin command "$@"; }',
      'ruby() { echo "cannot load openssl" >&2; return 1; }'
    ]
    stubs.each do |stub|
      output, error, status = build_configuration(ruby_stub: stub)
      assert status.success?, error
      assert_equal '-|auto', output
      assert_includes error, 'Signing discovery unavailable'
    end
  end

  def test_malformed_helper_output_is_not_used_as_a_signing_identity
    ['', 'not-a-fingerprint\\nnone', "#{FINGERPRINT}\\ninvalid", "#{FINGERPRINT}\\nnone\\nextra"].each do |text|
      output, error, status = build_configuration(ruby_stub: "ruby() { printf '#{text}'; }")
      assert status.success?, error
      assert_equal '-|auto', output
      assert_includes error, 'Invalid signing discovery output'
    end
  end

  def test_fallback_preserves_explicit_timestamp
    output, error, status = build_configuration(
      ruby_stub: 'ruby() { return 1; }', env: { 'CODE_SIGN_TIMESTAMP' => 'none' }
    )
    assert status.success?, error
    assert_equal '-|none', output
  end

  def test_real_signing_failure_still_stops_the_build
    [nil, 'EXPLICIT_CERTIFICATE'].each do |identity|
      _, error, status = build_configuration(
        env: { 'CODE_SIGN_IDENTITY' => identity },
        ruby_stub: "ruby() { printf '#{FINGERPRINT}\\nnone\\n'; }\n" +
          'codesign() { echo "signing failed" >&2; return 7; }',
        command: 'sign_path /unused/test-app com.example.test; echo "must not continue" >&2'
      )
      assert_equal 7, status.exitstatus
      assert_includes error, 'signing failed'
      refute_includes error, 'must not continue'
    end
  end

  def test_signing_receives_selected_identity_entitlements_and_timestamp_policy
    ['none', 'auto'].each do |timestamp|
      output, error, status = build_configuration(
        ruby_stub: "ruby() { printf '#{FINGERPRINT}\\n#{timestamp}\\n'; }\n" +
          'codesign() { printf "%s\\n" "$@"; }',
        command: 'sign_path /unused/test-app com.example.test /unused/entitlements'
      )
      assert status.success?, error
      arguments = output.lines.map(&:chomp)
      assert_equal FINGERPRINT, arguments[arguments.index('--sign') + 1]
      assert_equal '/unused/entitlements', arguments[arguments.index('--entitlements') + 1]
      assert_includes arguments, timestamp == 'none' ? '--timestamp=none' : '--timestamp'
    end
  end
end
