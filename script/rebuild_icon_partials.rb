#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regenerates every ERB partial in `app/views/icons/_*.html.erb` whose key is
# mapped to a Phosphor Duotone icon in `config/phosphor_name_map.yml`.
#
# Usage:
#   ruby script/rebuild_icon_partials.rb                 # writes in place
#   ruby script/rebuild_icon_partials.rb --dry-run       # prints the target path only
#   PHOSPHOR_ASSET_DIR=/path/to/duotone ruby script/...  # override source dir
#
# Source of the SVGs (first existing path wins):
#   1. $PHOSPHOR_ASSET_DIR
#   2. node_modules/@phosphor-icons/core/assets/duotone
#   3. tmp/phosphor-fetch/node_modules/@phosphor-icons/core/assets/duotone
#
# Idempotent. Safe to rerun after editing the YAML map.

require 'yaml'
require 'fileutils'

ROOT        = File.expand_path('..', __dir__)
MAP_PATH    = File.join(ROOT, 'config/phosphor_name_map.yml')
ICONS_DIR   = File.join(ROOT, 'app/views/icons')
DRY_RUN     = ARGV.include?('--dry-run')

CANDIDATE_ASSET_DIRS = [
  ENV['PHOSPHOR_ASSET_DIR'],
  File.join(ROOT, 'node_modules/@phosphor-icons/core/assets/duotone'),
  File.join(ROOT, 'tmp/phosphor-fetch/node_modules/@phosphor-icons/core/assets/duotone')
].compact

ASSET_DIR = CANDIDATE_ASSET_DIRS.find { |d| File.directory?(d) }
abort "Phosphor duotone assets not found. Run `yarn install` or set PHOSPHOR_ASSET_DIR." unless ASSET_DIR
puts "Using Phosphor assets at: #{ASSET_DIR}"

# Regex for Phosphor duotone SVGs which are always a single-line file:
#   <svg ...><path d="..." opacity="0.2"/><path d="..."/></svg>
# We capture every <path .../> and split by presence of opacity.
PATH_RE = /<path\s+([^>]*?)\s*\/?>/.freeze

def parse_paths(svg_text)
  paths = svg_text.scan(PATH_RE).map(&:first).map do |attrs|
    d = attrs[/d="([^"]*)"/, 1]
    has_opacity = attrs.include?('opacity="0.2"')
    { d: d, opacity: has_opacity }
  end
  raise 'no <path> elements found' if paths.empty?

  paths
end

def build_partial(fill_paths, outline_paths, accent_default)
  # Phosphor duotone always emits fill layer(s) first with opacity=0.2, then outline layer(s).
  # We preserve the ordering (fill below, outline above) and wire both layers to the ERB class hooks.
  accent_attr = accent_default.to_s.strip.empty? ? '' : accent_default
  accent_expr = accent_attr.empty? ? %q(<%= local_assigns[:accent_class] %>) : %Q(<%= local_assigns[:accent_class] || '#{accent_attr}' %>)

  lines = []
  lines << %q(<svg xmlns="http://www.w3.org/2000/svg" class="<%= local_assigns[:class] %>" viewBox="0 0 256 256" fill="currentColor">)
  fill_paths.each do |p|
    lines << %Q(  <path class="#{accent_expr}" opacity="0.2" d="#{p[:d]}"></path>)
  end
  outline_paths.each do |p|
    lines << %Q(  <path d="#{p[:d]}"></path>)
  end
  lines << '</svg>'
  "#{lines.join("\n")}\n"
end

map = YAML.safe_load(File.read(MAP_PATH))

regenerated = 0
skipped_keep = 0
skipped_no_partial = 0
missing = []

map.each do |key, entry|
  target = File.join(ICONS_DIR, "_#{key}.html.erb")

  unless File.file?(target)
    skipped_no_partial += 1 # Vue-only names live in the YAML too; no ERB file to rewrite
    next
  end

  if entry.is_a?(Hash) && (entry['keep_existing'] || entry['keep_existing_erb'])
    skipped_keep += 1
    next
  end

  phosphor_name = entry.is_a?(Hash) ? entry['phosphor'] : nil
  unless phosphor_name
    missing << "#{key}: no phosphor: set"
    next
  end

  svg_path = File.join(ASSET_DIR, "#{phosphor_name}-duotone.svg")
  unless File.file?(svg_path)
    missing << "#{key} -> #{phosphor_name} (missing SVG at #{svg_path})"
    next
  end

  svg_text = File.read(svg_path).strip
  paths = parse_paths(svg_text)
  fill_paths = paths.select { |p| p[:opacity] }
  outline_paths = paths.reject { |p| p[:opacity] }
  # Some duotone icons have no opacity="0.2" layer (rare -- a few logos). Fall back: use the first path as fill,
  # the rest as outline.
  if fill_paths.empty? && paths.length >= 2
    fill_paths = [paths.first]
    outline_paths = paths[1..]
  end

  accent_default = entry.is_a?(Hash) ? entry['accent'].to_s : ''
  output = build_partial(fill_paths, outline_paths, accent_default)

  if DRY_RUN
    puts "DRY  #{target}"
  else
    File.write(target, output)
    puts "WROTE #{target}"
  end

  regenerated += 1
end

puts "\nSummary:"
puts "  regenerated:      #{regenerated}"
puts "  kept (brand):     #{skipped_keep}"
puts "  vue-only keys:    #{skipped_no_partial}"
puts "  missing:          #{missing.size}"
missing.each { |m| puts "    - #{m}" }
exit 1 if missing.any?
