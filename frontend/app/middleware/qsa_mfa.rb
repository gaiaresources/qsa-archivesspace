class QSAMultiFactorAuthentication
  def initialize(app)
    @app = app
  end

  def call(env)
    request = Rack::Request.new(env)

    if ['needs_check', 'unconfigured'].include?(request.session[:mfa_status])
      unless request.path.start_with?('/mfa/') || request.path =~ %r{\A/assets/}
        return [302, { 'Location' => '/mfa/challenge' }, []]
      end
    end

    status, headers, response = @app.call(env)

    [status, headers, response]
  end
end
