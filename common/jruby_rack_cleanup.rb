if defined?(Rack::Handler::Servlet::DefaultEnv)

  $stderr.puts("***\n" +
               "*** Applying Rack file leak workaround\n" +
               "***")

  Rack::Handler::Servlet::DefaultEnv.class_eval do
    class << self
      unless method_defined?(:pre_rack_cleanup_create)
        alias_method :pre_rack_cleanup_create, :create

        def create(servlet_env)
          result = pre_rack_cleanup_create(servlet_env)
          result['java.servlet_request'].setAttribute("aspace_rack_input", result['rack.input'])
          result
        end
      end
    end
  end

else

  $stderr.puts("***\n" +
               "*** Rack file leak workaround not applicable in this environment\n" +
               "***")

end
