module I18nQSA

  def translate(locale, key, options)
    result = super

    if key.is_a?(String) && key.end_with?(".")
      return options.fetch(:default, '')
    end

    result
  end

end

I18n::Backend::Simple.send(:include, I18nQSA)
