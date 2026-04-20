# frozen_string_literal: true

require 'kramdown'
require 'kramdown-parser-gfm'

module Docs
  # Renders GitHub-flavored Markdown from +docs/+. Fenced code blocks keep
  # their +language-*+ class so a client-side highlighter (e.g. Prism / hljs)
  # can colorize them later; no server-side highlighter is loaded because
  # Rouge 4.7.0 eager-loads every lexer on +require+ and one of them
  # (+apiblueprint+) raises on Ruby 4.x, which takes the page down.
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

      Kramdown::Document.new(
        text,
        input: 'GFM',
        syntax_highlighter: nil,
        hard_wrap: false,
        auto_ids: true
      ).to_html
    end

    def mtime(filename)
      path = Rails.root.join('docs', filename)
      path.mtime if path.file?
    end
  end
end
