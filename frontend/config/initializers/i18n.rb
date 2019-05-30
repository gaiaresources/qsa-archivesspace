require 'aspace_i18n_enumeration_support'
require 'mixed_content_parser'

# Disable I18n caching in dev mode
if Rails.env == 'development'
  module I18n
    def self.t_raw(*args)
      return self.t_raw_uncached(*args)
    end
  end
end

module ActionView
  module Helpers
    module TranslationHelperDecorator
      private

      def html_safe_translation_key?(key)
        true
      end
    end
  end
end

ActionView::Helpers::TranslationHelper.prepend(ActionView::Helpers::TranslationHelperDecorator)


# TODO Remove
class JSONModelI18nWrapper < Hash
  def initialize(args)
    super
  end

  def enable_parse_mixed_content!(path = '/')
    true
  end
end
