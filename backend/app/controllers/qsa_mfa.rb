class ArchivesSpaceService < Sinatra::Base

  Endpoint.post('/mfa/save-settings')
    .description("Save a user's MFA settings")
    .params(["mfa_method", String, "The MFA method selected"],
            ["phone_number", String, "The phone number (for SMS)", :optional => true],
            ["totp_secret", String, "The TOTP secret (for TOTP)", :optional => true],
            )
    .permissions([])
    .returns([200, :saved],
             [400, :error]) \
  do
    mfa_method = params[:mfa_method]

    raise "Unknown MFA method: #{mfa_method}" unless ['sms', 'totp'].include?(mfa_method)

    mfa_token = if mfa_method == 'sms'
                  params[:phone_number]
                else
                  params[:totp_secret]
                end

    MFA.save_unconfirmed(
      current_user.id,
      params[:mfa_method],
      mfa_token
    )

    json_response(:status => "OK")
  end

  Endpoint.post('/mfa/issue-challenge')
    .description('Issue an MFA challenge to the current user')
    .params(["mode", String, "confirmed or check"])
    .permissions([])
    .returns([200, :ok]) \
  do
    MFA.issue_challenge(current_user.id, params[:mode].intern)

    json_response(:status => "OK")
  end

  Endpoint.post('/mfa/resend-challenge')
    .description('Resend the MFA challenge to the current user')
    .params(["mode", String, "confirmed or check"])
    .permissions([])
    .returns([200, :ok]) \
  do
    status = MFA.resend_challenge(current_user.id, params[:mode].intern)

    json_response(:status => status.to_s)
  end

  Endpoint.post('/mfa/validate')
    .description("Verify an MFA response")
    .params(["challenge_response", String, "Your lucky answer"],
            ["mode", String, "confirmed or check"])
    .permissions([])
    .returns([200, :success],
             [400, :error]) \
  do
    result = MFA.validate(current_user.id, params[:challenge_response], params[:mode].intern)

    json_response(:status => result)
  end

  Endpoint.post('/mfa/reset-for-current-user')
    .description("Reset MFA settings for the logged in user")
    .permissions([])
    .returns([200, :success],
             [400, :error]) \
  do
    MFA.reset_mfa(current_user.id)
    json_response(:status => "OK")
  end

  Endpoint.post('/mfa/reset-for-user')
    .description("Reset MFA settings for a selected user")
    .params(["user_id", Integer, "Target User ID"])
    .permissions([:manage_users])
    .returns([200, :success],
             [400, :error]) \
  do
    MFA.reset_mfa(params[:user_id])
    json_response(:status => "OK")
  end

end
