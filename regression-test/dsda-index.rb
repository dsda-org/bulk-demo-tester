#!/usr/bin/env ruby
# spec/dsda-index.rb
require_relative "support/dsda-common"
require_relative "support/dsda-test-prefs"
include DSDA

require 'optparse'

options = { threads: 5, meta_threads: 8, max_retries: 5, per: DSDA::PER_PAGE, skip_wad_meta: false }
DSDA.normalize_help_flags!(ARGV)

opt = OptionParser.new
opt.banner = <<~BANNER
  Usage:
    ruby dsda-index.rb [options]

  Examples:
    ruby dsda-index.rb
    ruby dsda-index.rb --threads 8
    ruby dsda-index.rb --skip-wad-meta

BANNER
opt.on("--threads N", Integer, "Indexing threads (default 5)") { |v| options[:threads] = v }
opt.on("--meta-threads N", Integer, "WAD metadata threads (default 8)") { |v| options[:meta_threads] = v }
opt.on("--per N", Integer, "Per-page (default 200)") { |v| options[:per] = v }
opt.on("--max-retries N", Integer, "Retries per page") { |v| options[:max_retries] = v }
opt.on("--skip-wad-meta", "Do not fetch WAD metadata/IWAD info") { options[:skip_wad_meta] = true }
opt.on("-h", "--h", "--help") { puts opt; exit }
opt.parse!(ARGV)

puts "🔎 Fetching first page to compute total_pages..."
first_url = "#{DSDA::DSDA_API}/demos?per=#{options[:per]}"
first_data = DSDA.http_get_json(first_url)

total_pages = first_data["total_pages"] || ((first_data["total_demos"] || 0) / options[:per].to_f).ceil
total_pages = 1 if total_pages.nil? || total_pages < 1
puts "ℹ️ Full index mode: total_pages=#{total_pages} (per=#{options[:per]})"

start = Time.now
puts "🚀 Parallel indexing using #{options[:threads]} threads..."
wad_map = DSDA.fast_index_all_pages(total_pages, threads: options[:threads], max_retries: options[:max_retries], per: options[:per])

wad_meta = {}
unless options[:skip_wad_meta]
  puts "🔎 Fetching WAD metadata for #{wad_map.keys.length} WADs..."
  wad_meta = DSDA.fetch_wad_meta_map(wad_map.keys, threads: options[:meta_threads], max_retries: options[:max_retries])
end

DSDA.save_index(wad_map, per: options[:per], wad_meta: wad_meta)
elapsed = Time.now - start
puts "💾 Saved index cache to #{DSDA.index_cache_path}"
puts "✅ Indexing complete — wads: #{wad_map.keys.length}, wad metadata: #{wad_meta.length}, time: #{format_duration(elapsed)}"
