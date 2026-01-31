# frozen_string_literal: true

module PhoneVerificationCodes
  DRIFT_BEHIND = 10.minutes

  module_function

  def generate(value)
    totp = ROTP::TOTP.new(build_totp_secret(value), digits: 6)

    totp.at(Time.current)
  end

  def verify(code, value)
    totp = ROTP::TOTP.new(build_totp_secret(value), digits: 6)

    totp.verify(code, drift_behind: DRIFT_BEHIND)
  end

  def build_totp_secret(value)
    ROTP::Base32.encode(
      Digest::SHA1.digest(
        [Rails.application.secret_key_base, 'phone_otp', value].join(':')
      )
    )
  end
end
