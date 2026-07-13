require 'bcrypt'
require 'base64'
require 'securerandom'

class DBAuth

  extend JSONModel
  include BCrypt

  def self.set_password(username, password)
    pwhash = Password.create(password)
    username = username.downcase

    DB.open do |db|
      DB.attempt {
        db[:auth_db].insert(:username => username,
                            :pwhash => pwhash,
                            :create_time => Time.now,
                            :system_mtime => Time.now)
      }.and_if_constraint_fails {
        db[:auth_db].
        filter(:username => username).
        update(:username => username,
               :pwhash => pwhash,
               :system_mtime => Time.now)
      }

      db[:auth_db].filter(:username => username).update(:successive_login_failure_count => 0)

      user = db[:user].filter(:username => username).first
      db[:mfa_challenge].filter(:user_id => user.fetch(:id)).delete
    end
  end

  FAKE_HASH = Password.create(SecureRandom.hex)
  FAKE_PASSWORD = SecureRandom.hex

  def self.authenticate(username, password)
    username = username.downcase

    DB.open do |db|
      pwhash = db[:auth_db].filter(:username => username).get(:pwhash)

      # Avoid timing attack by doing BCrypt rounds even when the user wasn't found
      unless pwhash
        Password.new(FAKE_HASH) == FAKE_PASSWORD
        return nil
      end

      if Password.new(pwhash) == password
        db[:auth_db].filter(:username => username).update(
          :successive_login_failure_count => 0,
          :last_login_success_time => java.lang.System.currentTimeMillis
        )

        user = User.find(:username => username)

        JSONModel(:user).from_hash(
          :username => username,
          :name => user.name,
          :email => user.email,
          :first_name => user.first_name,
          :last_name => user.last_name,
          :telephone => user.telephone,
          :title => user.title,
          :department => user.department,
          :additional_contact => user.additional_contact
        )
      else
        db[:auth_db].filter(:username => username).update(
          :successive_login_failure_count => Sequel[:successive_login_failure_count] + 1,
          :last_login_failure_time => java.lang.System.currentTimeMillis
        )

        if (failure_count = db[:auth_db].filter(:username => username).get(:successive_login_failure_count)) == AppConfig[:login_max_attempts]
          Log.info("User #{username} has failed password authentication #{failure_count} times.  Account is now locked.")

          lock_account_and_email!(username)
        end

        nil
      end
    end
  end

  def self.lock_account_and_email!(username)
    self.lock_account(username)
    AccountLockedNotification.new(User.find(:username => username)).send!
  end

  def self.lock_account(username)
    DB.open do |db|
      db[:auth_db].filter(:username => username).update(:pwhash => BCrypt::Password.create(SecureRandom.hex(64)))
    end
  end


  def self.matching_usernames(query)
    DB.open do |db|
      query = query.gsub(/[%]/, '').downcase
      db[:auth_db].left_outer_join(:user, :username => :username).
                   filter(Sequel.~(:is_system_user => 1)).
                   filter(Sequel.like(Sequel.function(:lower, :auth_db__username),
                                      "#{query}%")).
        select(:auth_db__username).
        limit(AppConfig[:max_usernames_per_source].to_i).
        map {|row| row[:username]}
    end
  end


  def self.delete_user(username)
    DB.open do |db|
      db[:auth_db].filter(:username => username).delete
    end
  end


  def self.generate_token(username)
    user = User.find(username: username)
    user.system_mtime = Time.now
    user.save
    user = User.find(username: username)
    DB.open do |db|
      pwhash = db[:auth_db].filter(username: username).get(:pwhash)
      raise "Cannot generate token for passwordless users" if pwhash.nil?
      raw_token = Password.create([user.system_mtime, pwhash].join)
      return Base64.urlsafe_encode64(raw_token)
    end
  end


  def self.authenticate_token(username, token)
    user = User.find(username: username)
    if user.system_mtime < Time.now - 30*60
      return nil
    end
    token = Base64.urlsafe_decode64(token)
    DB.open do |db|
      pwhash = db[:auth_db].filter(username: username).get(:pwhash)
      if pwhash && (Password.new(token) == [user.system_mtime, pwhash].join)
        # void the old password and the token at the same time
        db[:auth_db].filter(username: username).update(pwhash: token)
        user = User.find(username: username)
        User.to_jsonmodel(user)
      else
        nil
      end
    end
  end
end
