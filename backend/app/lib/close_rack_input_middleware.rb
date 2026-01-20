class CloseRackInputMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  ensure
    env['rack.input'].close if env['rack.input'].respond_to?(:close)
  end
end
