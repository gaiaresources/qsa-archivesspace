require 'sms'

class MFA

  # Return the current status of the user's Multi-Factor Authentication
  #
  # Can be one of:
  #
  #  'unconfigured' -- the user hasn't set up MFA yet, but needs to.
  #  'already_checked' -- the user has completed MFA in the past AppConfig[:mfa_remember_me_seconds] seconds
  #  'needs_check' -- the user should receive an MFA challenge
  #
  def self.get_mfa_status(user_id)
    if AppConfig[:mfa_disabled]
      return 'already_checked'
    end

    DB.open do |db|
      last_mfa_success = [
        db[:mfa_sms].filter(:user_id => user_id, :confirmed => 1).get(:last_success),
        db[:mfa_keys].filter(:user_id => user_id, :confirmed => 1).get(:last_success)
      ].compact.max

      now = java.lang.System.currentTimeMillis

      if last_mfa_success.nil?
        'unconfigured'
      elsif (now - last_mfa_success) < (AppConfig[:mfa_remember_me_seconds] * 1000)
        'already_checked'
      else
        'needs_check'
      end
    end
  end

  def self.reset_mfa(user_id)
    DB.open do |db|
      db[:mfa_sms].filter(user_id: user_id).delete
      db[:mfa_keys].filter(user_id: user_id).delete
      db[:mfa_challenge].filter(user_id: user_id).delete
    end
  end


  # Save the current user's MFA method as an unconfirmed value.
  #
  # `mfa_method` is either 'sms' or 'totp', and `mfa_token` is correspondingly
  # either a phone number or a TOTP base32 secret.
  #
  def self.save_unconfirmed(user_id, mfa_method, mfa_token)
    raise "Unknown MFA method: #{mfa_method}" unless ['sms', 'totp'].include?(mfa_method)

    DB.open do |db|
      # Clear any existing pending tokens
      db[:mfa_sms].filter(user_id: user_id, confirmed: 0).delete
      db[:mfa_keys].filter(user_id: user_id, confirmed: 0).delete

      if mfa_method == 'sms'
        db[:mfa_sms].insert(user_id: user_id,
                            phone_number: mfa_token,
                            create_time: java.lang.System.currentTimeMillis,
                            last_success: 0,
                            confirmed: 0,
                           )
      elsif mfa_method == 'totp'
        db[:mfa_keys].insert(user_id: user_id,
                             key: mfa_token,
                             create_time: java.lang.System.currentTimeMillis,
                             last_success: 0,
                             confirmed: 0,
                            )
      else
        raise "BUG: Not all MFA methods covered"
      end
    end
  end

  # Promote the user's unconfirmed MFA into the confirmed one
  def self.confirm_new_mfa(user_id)
    DB.open do |db|
      db[:mfa_sms].filter(user_id: user_id, confirmed: 1).delete
      db[:mfa_keys].filter(user_id: user_id, confirmed: 1).delete

      db[:mfa_sms].filter(user_id: user_id, confirmed: 0).update(confirmed: 1)
      db[:mfa_keys].filter(user_id: user_id, confirmed: 0).update(confirmed: 1)
    end
  end

  def self.find_authenticator(db, user_id, confirmed_value)
    authenticator = [[:mfa_sms, SMS], [:mfa_keys, TOTP]].lazy.map do |(table, clz)|
      if (row = db[table].filter(user_id: user_id, confirmed: confirmed_value).first)
        clz.from_row(row)
      end
    end.compact.first

    raise "Authenticator not found for user_id=#{user_id} and confirmed=#{confirmed_value}" unless authenticator

    authenticator
  end

  def self.log_success(db, user_id, confirmed_value)
    [:mfa_sms, :mfa_keys].each do |table|
      db[table].filter(user_id: user_id, confirmed: confirmed_value).update(:last_success => java.lang.System.currentTimeMillis)
    end
  end

  # Resend the challenge to the specified user
  #
  # For SMS, send the SMS again
  #
  # For TOTP, do nothing
  def self.resend_challenge(user_id, mode = :confirmed)
    raise "Invalid mode: #{mode}" unless [:confirmed, :check].include?(mode)

    confirmed_value = (mode == :confirmed ? 1 : 0)

    DB.open do |db|
      authenticator = find_authenticator(db, user_id, confirmed_value)

      if (challenge = db[:mfa_challenge].filter(user_id: user_id, type: mode.to_s).first)
        authenticator.resend_challenge(challenge.fetch(:state))
      else
        :no_active_challenge
      end
    end
  end

  # Issue a challenge against the user's MFA
  #
  # If mode is :confirmed, use their previously confirmed MFA setting.
  #
  # If mode is :check, use their unconfirmed MFA setting and confirm it on success.
  #
  def self.issue_challenge(user_id, mode = :confirmed)
    raise "Invalid mode: #{mode}" unless [:confirmed, :check].include?(mode)

    confirmed_value = (mode == :confirmed ? 1 : 0)

    DB.open do |db|
      authenticator = find_authenticator(db, user_id, confirmed_value)

      db[:mfa_challenge].filter(user_id: user_id, type: mode.to_s).delete
      db[:mfa_challenge].insert(authenticator.issue_challenge.merge(
                                  user_id: user_id,
                                  key: SecureRandom.hex,
                                  type: mode.to_s,
                                  expires_after: java.lang.System.currentTimeMillis + (AppConfig[:mfa_expire_seconds] * 1000),
                                  attempts: 0,
                                  status: '',
                                ))
    end
  end

  # Validate a challenge response against the user's MFA.
  #
  # If mode is :confirmed, use their previously confirmed MFA setting.
  #
  # If mode is :check, use their unconfirmed MFA setting and confirm it on success.
  #
  def self.validate(user_id, challenge_response, mode = :confirmed)
    raise "Invalid mode: #{mode}" unless [:confirmed, :check].include?(mode)

    confirmed_value = (mode == :confirmed ? 1 : 0)

    result = :gone

    DB.open do |db|
      # Expire any old challenges
      now = java.lang.System.currentTimeMillis
      db[:mfa_challenge].where { expires_after <= now }.delete

      # Expire any challenges that have run out of attempts
      max_attempts = AppConfig[:mfa_max_attempts]
      db[:mfa_challenge].where { attempts >= max_attempts }.delete

      authenticator = find_authenticator(db, user_id, confirmed_value)

      challenge = db[:mfa_challenge].filter(user_id: user_id, type: mode.to_s).first

      # No valid challenge: you lose.
      unless challenge
        Log.info("No valid challenge found for user_id=#{user_id} and mode #{mode}")
        return result
      end

      if authenticator.validate(challenge.fetch(:state), challenge_response)
        result = :correct
        confirm_new_mfa(user_id) if mode == :check
        log_success(db, user_id, confirmed_value)
        db[:mfa_challenge].filter(user_id: user_id, type: mode.to_s).delete
      else
        result = :incorrect
        db[:mfa_challenge].filter(user_id: user_id, type: mode.to_s).update(attempts: Sequel.expr(:attempts) + 1)

        new_count = db[:mfa_challenge].filter(user_id: user_id, type: mode.to_s).get(:attempts)

        if new_count == max_attempts
          result = :max_reached
          if mode == :confirmed
            DBAuth.lock_account_and_email!(db[:user].filter(:id => user_id).get(:username))
          end
        end
      end
    end

    result
  end

  class SMS
    def self.from_row(row)
      new(row)
    end

    def initialize(row)
      @row = row
    end

    def validate(challenge, challenge_response)
      challenge_response = challenge_response.to_s.gsub(/[^0-9]/, '')

      return false if challenge.length != challenge_response.length

      valid = true

      challenge.chars.zip(challenge_response.chars).each do |ch1, ch2|
        valid &= (ch1 == ch2)
      end

      valid
    end

    def issue_challenge
      code = generate_code(AppConfig[:mfa_challenge_length])

      DB.after_commit do
        send_sms(code)
      end

      {
        state: code
      }
    end

    def resend_challenge(challenge)
      send_sms(challenge)
      :sent
    end

    private

    def send_sms(challenge)
      ::SMS.new(Log).send_message(number: @row.fetch(:phone_number),
                                  message: "Your MFA code for ArchivesSpace is #{challenge}",
                                  sender: "QSA")
    end

    def generate_code(digit_count)
      result = []

      # Unbiased digit
      while result.length < digit_count
        b = SecureRandom.random_bytes(1).ord
        # Discard 250..255 as these would bias towards low digits
        if b < 250
          result << (b % 10)
        end
      end

      result.map(&:to_s).join('')
    end

  end

  class TOTP
    def self.from_row(row)
      new(row)
    end

    def initialize(row)
      @row = row
    end

    def validate(_challenge, challenge_response)
      totp = ROTP::TOTP.new(@row.fetch(:key))
      totp.verify(challenge_response, drift_ahead: 30, drift_behind: 30)
    end

    def issue_challenge
      # Nothing to do for TOTP
      {
        state: ''
      }
    end

    def resend_challenge(_challenge)
      # Nothing to do for TOTP
      :not_applicable
    end
  end

end
