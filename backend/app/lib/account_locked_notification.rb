class AccountLockedNotification

  EMAIL_BODY = "
<html>
    <body>
        <h2>Your ArchivesSpace account has been locked</h2>

        <p>Hi <%= name %>,</p>

        <p>
            Due to several authentication failures in a row, your ArchivesSpace
            account has been automatically locked.  To log in again, you will
            need to reset your account password by using the link below.
        </p>

        <p><a href='<%= AppConfig[:frontend_proxy_url].gsub(%r{/+$}, '') %>/password_reset'>Reset my password</a></p>
    </body>
</html>
  "

  def initialize(user)
    @user = user
  end

  def send!
    # NOTE: using EmailDelivery from as_runcorn here to match the settings we
    # use for other emails

    user_email = @user.email.to_s.strip

    if user_email.empty?
      Log.error("ERROR: Can't send a password reset for a user without an email address recorded: #{@user.username}")
    else
      EmailDelivery
        .new("Your ArchivesSpace account has been locked",
             ERB.new(EMAIL_BODY).result_with_hash(name: @user.name),
             [user_email],
            )
        .send!
    end
  end
end
