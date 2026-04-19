# frozen_string_literal: true

module Docs
  # Tight allowlist for rendered Markdown (trusted repo content; still avoid XSS if a link is odd).
  module HtmlSanitize
    ALLOWED_TAGS = %w[
      h1 h2 h3 h4 h5 h6 p blockquote pre code span div ul ol li
      table thead tbody tr th td a hr br strong em b i del sub sup
    ].freeze
    ALLOWED_ATTRS = %w[href id class title colspan rowspan scope].freeze

    module_function

    def call(html)
      ActionController::Base.helpers.sanitize(html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRS)
    end
  end
end
