require 'json'
require 'open3'
require 'openssl'
require 'timeout'

module SigningIdentity
  APP_IDENTIFIER = 'com.ljh740.XCodeMCPStatusBar'.freeze
  APPLE_REFERENCE_DATE = Time.utc(2001, 1, 1).to_i

  def self.authorized_teams(permissions, now:)
    return [] unless permissions.is_a?(Hash) && permissions['permission'].is_a?(Hash)

    agents = permissions['permission']['permittedAgents']
    return [] unless agents.is_a?(Array)

    agents.map do |agent|
      next unless agent.is_a?(Hash) && agent['trust'].is_a?(Hash)

      signed = agent['trust']['signed']
      next unless signed.is_a?(Hash) && signed['signingIdentifier'] == APP_IDENTIFIER

      expiration = signed['expiration']
      # mcp-server 的 JSON 日期采用 Foundation 的 2001 年参考时间。
      next unless expiration.nil? ||
                  (expiration.is_a?(Numeric) && expiration.finite? &&
                   expiration + APPLE_REFERENCE_DATE > now.to_f)

      signed['teamIdentifier']
    end.compact.uniq
  end

  def self.select(identities, certificates, permissions, now: Time.now)
    valid_hashes = identities.lines.map do |line|
      match = line.match(/^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"[^"]+"\s*$/)
      match[1].upcase if match
    end.compact
    candidates = certificates.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m).map do |pem|
      begin
        certificate = OpenSSL::X509::Certificate.new(pem)
      rescue OpenSSL::X509::CertificateError
        warn 'Ignoring a malformed Keychain certificate'
        next
      end
      fingerprint = OpenSSL::Digest::SHA1.hexdigest(certificate.to_der).upcase
      next unless valid_hashes.include?(fingerprint)
      next unless certificate.not_before <= now && now < certificate.not_after
      next if certificate.subject == certificate.issuer

      subject = certificate.subject.to_a.map { |name, value, _| [name, value] }.to_h
      issuer = certificate.issuer.to_a.map { |name, value, _| [name, value] }.to_h
      name = subject.fetch('CN', '')
      team = subject.fetch('OU', '')
      next unless issuer['O'] == 'Apple Inc.' && team.match?(/\A[A-Z0-9]{10}\z/)
      next unless name.start_with?('Apple Development:', 'Mac Developer:', 'Developer ID Application:')

      { fingerprint: fingerprint, name: name, team: team, expires: certificate.not_after }
    end.compact
    # 证书名称括号不是 Team ID；使用 OU 匹配已有授权，避免更新后无意切换签名身份。
    teams = candidates.map { |candidate| candidate[:team] }.uniq
    authorized = teams & authorized_teams(permissions, now: now)
    teams = authorized unless authorized.empty?
    if teams.length > 1
      warn "Multiple eligible signing teams (#{teams.sort.join(', ')}); set CODE_SIGN_IDENTITY explicitly"
      return nil
    end

    candidates.select { |candidate| candidate[:team] == teams.first }.min_by do |candidate|
      [candidate[:name].start_with?('Developer ID Application:') ? 1 : 0,
       -candidate[:expires].to_i, candidate[:fingerprint]]
    end
  end

  def self.capture(*command, timeout: 10)
    Open3.popen2(*command, err: File::NULL) do |stdin, stdout, wait_thread|
      stdin.close
      begin
        # 读取完 stdout 后仍需限时等待退出，避免提前关闭 stdout 的命令阻塞构建。
        Timeout.timeout(timeout) do
          output = stdout.read
          raise "Command failed: #{command.first}" unless wait_thread.value.success?

          output
        end
      rescue Timeout::Error
        begin
          Process.kill('KILL', wait_thread.pid) if wait_thread.alive?
        rescue Errno::ESRCH
          # 超时与进程退出可能同时发生，Open3 仍负责回收等待线程。
        end
        raise
      end
    end
  end

  def self.run
    identities = capture('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning')
    certificates = capture('/usr/bin/security', 'find-certificate', '-a', '-p')
    permissions = begin
      server = capture('/usr/bin/xcrun', '--find', 'mcp-server').strip
      JSON.parse(capture(server, 'status', '--format', 'json'))
    rescue StandardError => error
      warn "Existing Xcode signing preference unavailable: #{error.message}"
      {}
    end
    candidate = select(identities, certificates, permissions)
    if candidate
      warn "Auto-selected signing identity: #{candidate[:name]} (Team ID: #{candidate[:team]})"
      # 仅输出指纹和时间戳策略供 shell 读取；私钥始终留在 Keychain。
      puts candidate[:fingerprint]
      puts(candidate[:name].start_with?('Developer ID Application:') ? 'auto' : 'none')
    else
      warn 'No unambiguous valid Apple signing identity found; using ad-hoc signing'
      puts "-\nauto"
    end
  rescue StandardError => error
    warn "Signing identity discovery failed: #{error.message}; using ad-hoc signing"
    puts "-\nauto"
  end
end

SigningIdentity.run if $PROGRAM_NAME == __FILE__
