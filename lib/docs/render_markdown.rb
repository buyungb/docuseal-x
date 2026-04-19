# frozen_string_literal: true

require 'kramdown'
require 'kramdown-parser-gfm'

module Docs
  # Renders GitHub-flavored Markdown from +docs/+ with Rouge-highlighted fenced code.
  module RenderMarkdown
    module_function

    def call(filename)
      path = Rails.root.join('docs', filename)
      raise Errno::ENOENT, "docs/#{filename}" unless path.file?

      text = File.read(path, encoding: 'UTF-8')
      if filename == 'API.md'
        href = Rails.application.routes.url_helpers.template_tags_docs_path
        text = text.gsub('](./TEMPLATE_TAGS.md)', "](#{href})")
      end

      require 'rouge'

      Kramdown::Document.new(
        text,
        input: 'GFM',
        syntax_highlighter: :rouge,
        syntax_highlighter_opts: {
          span: { line_numbers: false },
          block: { line_numbers: false, wrap: true }
        }
      ).to_html
    end

    def mtime(filename)
      path = Rails.root.join('docs', filename)
      path.mtime if path.file?
    end
  end
end
