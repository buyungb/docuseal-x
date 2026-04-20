#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Rewrites every .vue file that imports `@tabler/icons-vue`:
#   import { IconWritingSign, IconX } from '@tabler/icons-vue'
# becomes
#   import { PhSignature, PhX } from '@phosphor-icons/vue'
#
# Then every `IconWritingSign` identifier in the file (component registry +
# template tag) is renamed to `PhSignature`, and every rewritten template tag
# gets `weight="duotone"` inserted unless it already specifies a weight.
#
# Usage:
#   ruby script/migrate_vue_icon_imports.rb                 # rewrite in place
#   ruby script/migrate_vue_icon_imports.rb --dry-run       # preview + list unmapped
#
# The source of truth for name translation is `config/phosphor_name_map.yml`.
# Any Tabler icon name that is not mapped in the YAML causes the script to exit
# non-zero and print a missing-mapping report.

require 'yaml'

ROOT      = File.expand_path('..', __dir__)
MAP_PATH  = File.join(ROOT, 'config/phosphor_name_map.yml')
JS_DIR    = File.join(ROOT, 'app/javascript')
DRY_RUN   = ARGV.include?('--dry-run')

raw_map = YAML.safe_load(File.read(MAP_PATH))

def snake_to_pascal(snake)
  snake.split('_').map { |p| p.empty? ? p : p[0].upcase + p[1..] }.join
end

def kebab_to_pascal(kebab)
  kebab.split('-').map { |p| p.empty? ? p : p[0].upcase + p[1..] }.join
end

# tabler_pascal (IconFoo) -> phosphor_pascal (PhBar)
TABLER_TO_PHOSPHOR = {}
raw_map.each do |key, entry|
  next unless entry.is_a?(Hash)

  phosphor = entry['phosphor']
  next unless phosphor

  tabler_pascal   = "Icon#{snake_to_pascal(key)}"
  phosphor_pascal = "Ph#{kebab_to_pascal(phosphor)}"
  TABLER_TO_PHOSPHOR[tabler_pascal] = phosphor_pascal
end

vue_files = Dir.glob(File.join(JS_DIR, '**', '*.vue'))
touched   = []
unmapped  = {}
skipped   = []

vue_files.each do |path|
  text = File.read(path)
  next unless text.include?("@tabler/icons-vue")

  import_re  = /^\s*import\s*\{([^}]+)\}\s*from\s*'@tabler\/icons-vue'\s*;?\s*$/
  import_match = text.match(import_re)
  unless import_match
    skipped << "#{path} (no import line matched)"
    next
  end

  tabler_names = import_match[1].split(',').map(&:strip).reject(&:empty?)
  missing_here = tabler_names.reject { |n| TABLER_TO_PHOSPHOR.key?(n) }

  unless missing_here.empty?
    missing_here.each { |n| (unmapped[n] ||= []) << path }
    next
  end

  phosphor_names = tabler_names.map { |n| TABLER_TO_PHOSPHOR.fetch(n) }.uniq
  # Preserve original order, keep uniques only
  ordered = []
  tabler_names.each do |n|
    p = TABLER_TO_PHOSPHOR.fetch(n)
    ordered << p unless ordered.include?(p)
  end

  # 1. Rewrite the import line
  new_import = "import { #{ordered.join(', ')} } from '@phosphor-icons/vue'"
  text = text.sub(import_re, new_import)

  # 2. Rename every `IconFoo` identifier to `PhBar` (word-boundary match).
  #    Process longer names first so `IconArrowsDiagonalMinimize2` isn't clobbered by
  #    `IconArrowsDiagonal`.
  tabler_names.sort_by { |n| -n.length }.uniq.each do |tabler|
    phosphor = TABLER_TO_PHOSPHOR.fetch(tabler)
    text.gsub!(/\b#{Regexp.escape(tabler)}\b/, phosphor)
  end

  # 3. Inject weight="duotone" into every Phosphor template tag that lacks a `weight=` attribute.
  #    Tag form: <PhBar ...attrs.../> or <PhBar ...attrs...>...</PhBar>
  ordered.each do |phosphor|
    text.gsub!(/<#{phosphor}((?:\s+[^>\/]*?)?)(\s*\/?)>/) do
      attrs = Regexp.last_match(1) || ''
      tail  = Regexp.last_match(2) || ''
      if attrs =~ /\bweight\s*=/
        "<#{phosphor}#{attrs}#{tail}>"
      else
        "<#{phosphor} weight=\"duotone\"#{attrs}#{tail}>"
      end
    end
  end

  if DRY_RUN
    puts "DRY  #{path}"
  else
    File.write(path, text)
    puts "WROTE #{path}"
  end
  touched << path
end

puts "\nSummary:"
puts "  touched:  #{touched.size}"
puts "  skipped:  #{skipped.size}"
skipped.each { |s| puts "    - #{s}" }

if unmapped.any?
  puts "  unmapped Tabler icons (add to config/phosphor_name_map.yml):"
  unmapped.each do |name, files|
    puts "    #{name}  (in #{files.size} file(s))"
    files.uniq.each { |f| puts "      - #{f}" }
  end
  exit 1
end
