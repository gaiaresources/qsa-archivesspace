class QsaMfaController < ApplicationController
  set_access_control :public => [:challenge, :validate, :settings, :resend_challenge, :save_email]
  set_access_control "view_repository" => [:reset_mfa_for_current_user]
  set_access_control "manage_users" => [:reset_mfa_for_user]

  def with_provisional_session
    candidate_session = session[:provisional_session]

    # Use a throw-away separate thread to sandbox the provisional user's backend
    # session from their main request thread.
    Thread.new do
      Thread.current[:backend_session] = candidate_session
      yield
    end.value
  end

  def challenge(mode = 'confirmed')
    # Common case: User is logging in and has previously setup MFA
    in_normal_operation = session[:mfa_status] == 'needs_check'

    # User has entered new MFA details but hasn't yet confirmed them
    setup_in_progress = session[:mfa_status] == 'unconfigured' && mode == 'check'

    if !session['mfa_status']
      # User hit this controller directly while not logged in?
      reset_session
      return redirect_to :controller => "welcome", :action => "index"
    end

    if (in_normal_operation || setup_in_progress) && !session['mfa_challenge_issued']
      response = with_provisional_session do
        JSONModel::HTTP.post_form('/mfa/issue-challenge', mode: mode)
      end

      if response.code == '200'
        # Challenge issued
        session['mfa_challenge_issued'] = true
      else
        raise "Invalid MFA response: #{response}"
      end
    end

    @mode = mode
    render :challenge
  end

  def reset_mfa_for_current_user
    response = JSONModel::HTTP.post_form('/mfa/reset-for-current-user')

    if response.code == '200'
      reset_session
      return redirect_to :controller => "welcome", :action => "index"
    else
      Rails.logger.error("Failed to reset MFA for current user: #{response}")
      flash[:error] = 'Failed to reset MFA for current user'
      return redirect_to :controller => "welcome", :action => "index"
    end
  end

  def reset_mfa_for_user
    username = params[:username]

    response = JSONModel::HTTP.post_form('/mfa/reset-for-user', user_id: params[:user_id])

    if response.code == '200'
      flash[:success] = "Successfully reset MFA for #{params[:username]}"
    else
      Rails.logger.error("Failed to reset MFA for current user: #{response}")
      flash[:error] = "Failed to reset MFA for #{params[:username]}"
    end

    redirect_to :controller => "users", :action => "index"
  end


  def save_email
    email = params[:email].to_s.strip
    confirm_email = params[:confirm_email].to_s.strip

    if email != confirm_email
      flash[:error] = 'Entered email addresses did not match'
      return redirect_to action: :challenge
    end

    success = with_provisional_session do
      response = JSONModel::HTTP.post_form('/mfa/save-email',
                                           email: email)

      response.code == '200'
    end

    if success
      session[:user_has_email_configured] = true
    else
      flash[:error] = 'There was a problem saving your email address.  Please check your address and try again.'
      return redirect_to action: :challenge
    end

    flash[:success] = 'Your email address was saved'
    return redirect_to action: :challenge
  end

  def clean_phone_number(s)
    s.to_s.gsub(/[^0-9]/, '')
  end

  def settings
    mfa_method = params[:mfa_method]

    if mfa_method == 'sms'
      if clean_phone_number(params[:phone_number]) != clean_phone_number(params[:phone_number_confirm])
        flash[:error] = 'Entered phone numbers did not match'
        return redirect_to action: :challenge
      end
    end

    response = with_provisional_session do
      JSONModel::HTTP.post_form('/mfa/save-settings',
                                mfa_method: mfa_method,
                                phone_number: clean_phone_number(params[:phone_number]),
                                totp_secret: params[:totp_secret])
    end

    if response.code == '200'
      challenge('check')
    else
      raise "Invalid MFA response: #{response}"
    end
  end

  def resend_challenge
    with_provisional_session do
      response = JSONModel::HTTP.post_form('/mfa/resend-challenge', mode: params[:mode])

      if response.code == '200'
        render :json => ASUtils.json_parse(response.body), :status => 200
      else
        raise "Failure re-issuing challenge: #{response}"
      end
    end
  end

  def validate
    challenge_response = params[:challenge_response]

    response = with_provisional_session do
      JSONModel::HTTP.post_form('/mfa/validate',
                                challenge_response: challenge_response,
                                mode: params[:mode])
    end

    if response.code == '200'
      json = ASUtils.json_parse(response.body)
      status = json.fetch('status', nil)

      if status == 'correct'
        session[:user] = session.delete(:provisional_user)
        session[:session] = session.delete(:provisional_session)

        session.delete(:mfa_status)

        return redirect_to :controller => "welcome", :action => "index"
      elsif status == 'incorrect'
        # Try again
        flash[:error] = "Failed check. Please try again."
        challenge(params[:mode])
      elsif status == 'max_reached'
        # If they actually hit the maximum, lock the account
        reset_session
        flash[:error] = "Maximum MFA attempts exceeded."
        return redirect_to :controller => "welcome", :action => "index"
      elsif status == 'gone'
        reset_session
        flash[:error] = "MFA challenge expired."
        return redirect_to :controller => "welcome", :action => "index"
      else
        raise "BUG: Unexpected MFA status: #{status}"
      end
    else
      raise "Invalid MFA response: #{response}"
    end
  end

end
