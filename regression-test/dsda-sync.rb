#!/usr/bin/env ruby
# spec/dsda-sync.rb
require_relative "support/dsda-common"
require_relative "support/dsda-test-prefs"
include DSDA

require 'optparse'

SCRIPT_DIR = __dir__
FileUtils.mkdir_p(DEMOS_ROOT)
FileUtils.mkdir_p(File.dirname(DSDA.index_cache_path))
FileUtils.mkdir_p(File.dirname(DSDA.state_cache_path))

options = {
  force: false,
  threads: 1,        # use threads for indexing tool, ruby doesn't like more
  skip_wads: false,
  skip_demos: false,
  refresh_index: false,
  retry_failed: false
}
DSDA.normalize_help_flags!(ARGV)

opt = OptionParser.new
opt.banner = <<~BANNER
  Usage:
    ruby dsda-sync.rb [IWAD[/WAD] | WAD] [options]

  Examples:
    ruby dsda-sync.rb doom
    ruby dsda-sync.rb doom/01fava
    ruby dsda-sync.rb 01fava

BANNER
opt.on("--force", "Force overwrite extracted content") { options[:force] = true }
opt.on("--skip-wads", "Don't download/extract wad zips") { options[:skip_wads] = true }
opt.on("--skip-demos", "Don't download/extract demo zips") { options[:skip_demos] = true }
opt.on("--refresh-index", "Ignore cached index and build a new one (recommended: run dsda-index.rb)") { options[:refresh_index] = true }
opt.on(*DSDA::FAILED_FLAGS, "Retry failed WADs and demos") { options[:retry_failed] = true }
opt.on("-h", "--h", "--help") { puts opt; exit }
opt.parse!(ARGV)

PRIMARY_IWADS = %w[doom2 doom plutonia tnt].freeze
EXOTIC_IWADS  = %w[heretic hexen chex].freeze
KNOWN_IWADS   = (PRIMARY_IWADS + EXOTIC_IWADS).freeze

state = DSDA.load_state(DSDA.state_cache_path)
state['failed_wads'] ||= {}

# load index
index = DSDA.load_index(DSDA.index_cache_path)
if index.nil? && !options[:refresh_index]
  puts "❌ No index cache found. Please run: ruby dsda-index.rb --threads 5"
  exit 1
end

# If refresh_index requested, or index missing, instruct user to run index
if options[:refresh_index]
  puts "❌ Refresh index requested — run dsda-index.rb separately (multi-threaded) and re-run dsda-sync.rb"
  exit 1
end

def fetch_wad_meta(wad_slug)
  begin
    DSDA.http_get_json("#{DSDA::DSDA_API}/wads/#{URI.encode_www_form_component(wad_slug)}")
  rescue => e
    raise "Failed fetching wad metadata: #{e.message}"
  end
end

def demo_zip_name(demo)
  zip_url = (demo['file'] || '').to_s.sub(/^http:/,'https:')
  File.basename(zip_url) rescue "demo_#{demo['id']}.zip"
end

def find_wad_key(wad_map, query)
  return nil if query.nil?

  wad_map.key?(query) ? query : wad_map.keys.find { |wad| wad.casecmp?(query) }
end

def select_sync_targets(raw_query, index)
  wad_map = index['wad_map']
  wad_meta = index['wad_meta'] || {}
  return wad_map.keys.map { |wad| { wad: wad } } if raw_query.nil? || raw_query.strip.empty?

  parts = raw_query.split('/').map(&:strip).reject(&:empty?)
  first = parts[0]&.downcase

  if KNOWN_IWADS.include?(first)
    iwad = first
    wad = parts[1]
    abort("❌ Sync selectors only support IWAD/WAD, not demo-level paths") if parts.size > 2

    unless wad
      puts "🎯 Syncing all WADs for IWAD #{iwad}"
      missing_meta = wad_map.keys.any? { |wad_slug| !wad_meta.key?(wad_slug) }
      if wad_meta.empty? || missing_meta
        abort("❌ This index does not include complete IWAD metadata.\n" \
              "Please re-run:\n" \
              "  ruby dsda-index.rb")
      end

      total = wad_map.keys.length
      found = 0

      return wad_map.keys.each_with_index.filter_map do |wad_slug, index|
        meta = wad_meta[wad_slug]
        meta_iwad = (meta['iwad'] || 'doom2').to_s.downcase
        found += 1 if meta_iwad == iwad

        if ((index + 1) % 25).zero? || index + 1 == total
          percent = ((index + 1).to_f / [total, 1].max * 100).round(1)
          puts "🔎 Scanning WAD metadata #{index + 1}/#{total} (#{percent}%) - found #{found} #{iwad}"
        end

        meta_iwad == iwad ? { wad: wad_slug, meta: meta } : nil
      rescue => e
        warn "⚠️ Skipping #{wad_slug}: #{e.message}"
        nil
      end
    end

    wad_key = find_wad_key(wad_map, wad)
    abort("❌ WAD '#{wad}' not found in index") unless wad_key

    meta = wad_meta[wad_key] || fetch_wad_meta(wad_key)
    meta_iwad = (meta['iwad'] || 'doom2').to_s.downcase
    abort("❌ WAD '#{wad_key}' belongs to #{meta_iwad}, not #{iwad}") unless meta_iwad == iwad

    return [{ wad: wad_key, meta: meta }]
  end

  abort("❌ Sync selectors only support WAD or IWAD/WAD, not demo-level paths") if parts.size > 1

  wad = parts[0]
  wad_key = find_wad_key(wad_map, wad)

  abort("❌ WAD '#{wad}' not found in index") unless wad_key
  [{ wad: wad_key }]
end

# Define sync_single_wad here to keep script self-contained and single-threaded
def sync_single_wad(wad_slug, state:, force: false, skip_wads: false, skip_demos: false, wad_meta: nil)
  puts "🔎 Fetching DSDA WAD metadata for: #{wad_slug}"
  wad_meta ||= fetch_wad_meta(wad_slug)

  unless wad_meta.is_a?(Hash)
    raise "Invalid WAD metadata received for #{wad_slug}"
  end

  short = wad_meta['short_name'] || wad_meta['name'] || wad_slug
  wad_name = DSDA.safe_name(short)
  iwad = wad_meta['iwad'] || 'doom2'

  wad_zip_url = (wad_meta['file'] || '').to_s.sub(/^http:/,'https:')
  has_downloadable_wad = !wad_zip_url.strip.empty?

  puts "📦 Found WAD: #{wad_name} (#{short})"
  puts "   IWAD: #{iwad}"
  if has_downloadable_wad
    puts "   ZIP:  #{wad_zip_url}"
  else
    puts "   ZIP:  (none — no downloadable WAD file)"
  end

  wad_root = File.join(DEMOS_ROOT, iwad, wad_name)
  wad_dir  = File.join(wad_root, "#{wad_name}-wad") # keep wad dir distinct with -wad suffix
  FileUtils.mkdir_p(wad_root)

  # Manual demo area for hand-managed demos; never touched by sync logic
  manual_dir = File.join(wad_root, "manual")
  FileUtils.mkdir_p(manual_dir) unless Dir.exist?(manual_dir)

  zip_filename = nil
  if has_downloadable_wad
    begin
      zip_filename = URI.parse(wad_zip_url).path&.split('/')&.last
    rescue
      zip_filename = nil
    end
  end
  zip_filename ||= "#{wad_name}.zip"
  zip_path = File.join(wad_root, zip_filename)
  wad_extraction_successful = false

  unless skip_wads
    if has_downloadable_wad
      if Dir.exist?(wad_dir) && DSDA.content_present?(wad_dir) && !force
        puts "🟢 WAD already extracted, skipping download/extract"
      else
        remote_size = DSDA.http_head_size(wad_zip_url)
        state['wad_meta'] ||= {}
        cached = state['wad_meta'].fetch(short, {})

        if File.exist?(zip_path) && !force && remote_size && File.size(zip_path) == remote_size
          puts "🟢 Found existing zip with matching size — reusing #{zip_path}"
        elsif !remote_size && cached['size'] && File.exist?(zip_path) && !force
          puts "🟢 Reusing existing zip (unknown remote size) - #{zip_path}"
        else
          puts "⬇️ Downloading WAD ZIP..."
          begin
            DSDA.download_file(wad_zip_url, zip_path)
          rescue => e
            raise "Failed to download WAD zip: #{e}"
          end
        end

        # If forcing, clean the wad_dir but *preserve* any existing /extra folder
        if force && Dir.exist?(wad_dir)
          puts "🧹 Cleaning WAD dir (preserving /extra): #{DSDA.display_path(wad_dir, File.expand_path('support', SCRIPT_DIR))}"
          Dir.children(wad_dir).each do |entry|
            # keep extra/ (case-insensitive, just in case)
            next if entry.downcase == "extra"

            path = File.join(wad_dir, entry)
            FileUtils.rm_rf(path)
          end
        end

        begin
          DSDA.extract_with_7z(zip_path, wad_dir)
          DSDA.cleanup_unwanted_files(wad_dir)
        rescue => e
          puts red("❌ WAD extraction failed: #{File.basename(zip_path)}")
          raise "Extraction failed: #{e}"
        ensure
          File.delete(zip_path) if File.exist?(zip_path)
        end
        wad_extraction_successful = true

        state['wad_meta'][short] = {
          'file' => wad_zip_url,
          'size' => DSDA.http_head_size(wad_zip_url),
          'updated_at' => Time.now.utc.iso8601
        }
      end
    else
      FileUtils.mkdir_p(wad_dir)
      puts "🟢 No downloadable WAD file — created metadata folder only."
    end

    # Try to get demo_count from index cache
    cached_index = DSDA.load_index(DSDA.index_cache_path)
    demo_count = cached_index ? (cached_index['wad_map'][short]&.length || 0) : 0

    info_path = File.join(wad_dir, "DSDA-info.txt")
    DSDA.write_dsda_info(info_path, {
      "Name"        => (wad_meta['name'] || wad_name),
      "ShortName"   => short,
      "IWAD"        => iwad,
      "DSDA WAD ID" => (wad_meta['id'].to_s.strip.empty? ? "(none)" : wad_meta['id'].to_s),
      "URL"         => "https://dsdarchive.com/wads/#{short}",
      "Authors"     => Array(wad_meta['author'] || wad_meta['authors']).join(", "),
      "Total demos" => demo_count,
      "Notes"       => (wad_meta['description'] || "")
    })
    puts "📝 WAD DSDA-info.txt written to #{DSDA.display_path(info_path)}"
    state['done_wads'][short] = true
    DSDA.save_state(state, DSDA.state_cache_path)
  end

  unless skip_demos
    puts "🔎 Fetching demos list for wad=#{wad_slug}..."
    page = 1
    demos = []
    loop do
      url = "#{DSDA::DSDA_API}/demos?wad=#{URI.encode_www_form_component(wad_slug)}&per=#{DSDA::PER_PAGE}&page=#{page}"
      data = DSDA.http_get_json(url)
      break if data.nil? || data['demos'].nil? || data['demos'].empty?
      demos.concat(data['demos'])
      break if data['demos'].length < (data['per'] || DSDA::PER_PAGE)
      page += 1
    end

    puts "📊 Found #{demos.length} demo entries for #{wad_slug}"
    puts green("✅ WAD extraction successful") if wad_extraction_successful
    puts
    puts "🎬 Starting sync for #{iwad}/#{wad_name} demos"

    demos.each_with_index do |demo, idx|
      demo ||= {}
      demo_id = demo['id'] || "unknown_#{idx}"
      zip_url = (demo['file'] || '').to_s.sub(/^http:/,'https:')
      zip_name = demo_zip_name(demo)
      demo_base = File.basename(zip_name, ".zip")

      # Final folder name that demos will be merged into
      merged_demo_folder = File.join(wad_root, demo_base)

      # Temporary extraction area (always unique)
      temp_demo_folder = File.join(wad_root, "#{demo_base}__tmp_#{demo_id}")

      engine = demo['engine'].to_s

      if DSDA.engine_should_skip?(engine)
        puts "⚠️ Skipping demo (unsupported engine: #{engine}) #{zip_name}"
        state['done_demos'][demo_id.to_s] = "skipped_engine:#{engine}"
        DSDA.save_state(state, DSDA.state_cache_path)
        puts
        next
      end

      if reason = DSDA.excluded_demo_zip_reason(iwad: iwad, wad: short, zip_name: zip_name, demo_id: demo_id, zip_url: zip_url)
        puts "⚠️ Skipping demo (excluded ZIP: #{zip_name}) #{reason}"
        state['done_demos'][demo_id.to_s] = "skipped_zip:#{zip_name}"
        state['failed_demos'].delete(demo_id.to_s)
        DSDA.save_state(state, DSDA.state_cache_path)
        puts
        next
      end

      # If we already processed this demo_id and the merged folder has content,
      # we can safely skip (re-running the sync) unless forcing.
      if state['done_demos'][demo_id.to_s] && DSDA.content_present?(merged_demo_folder) && !force
        puts "🟢 Demo #{zip_name} already processed — skipping"
        puts
        next
      end

      # Prepare fresh temp folder
      FileUtils.rm_rf(temp_demo_folder) if Dir.exist?(temp_demo_folder)
      FileUtils.mkdir_p(temp_demo_folder)

      tmp_zip = File.join(wad_root, zip_name)

      max_retries = 10
      attempt = 0
      begin
        puts "⬇️ (#{idx+1}/#{demos.length}) Downloading demo: #{zip_name} (attempt #{attempt+1}/#{max_retries})"
        DSDA.download_file(zip_url, tmp_zip)
      rescue => e
        attempt += 1
        if attempt < max_retries
          sleep_time = [0.5 * attempt, 5].min
          puts "⚠️  Download failed: #{e.message}. Retrying in #{sleep_time}s..."
          sleep sleep_time
          retry
        else
          puts red("❌ Demo download failed: #{zip_name} after #{max_retries} attempts")
          state['failed_demos'][demo_id.to_s] = "download_error:#{e}"
          DSDA.save_state(state, DSDA.state_cache_path)
          puts
          next
        end
      end

      begin
        FileUtils.rm_rf(temp_demo_folder) if force && Dir.exist?(temp_demo_folder)
        DSDA.extract_with_7z(tmp_zip, temp_demo_folder)
        DSDA.cleanup_unwanted_files(temp_demo_folder)
        File.delete(tmp_zip) if File.exist?(tmp_zip)

        # Write demo-specific DSDA-info.txt into the *temp* folder
        DSDA.write_dsda_info(File.join(temp_demo_folder, "DSDA-info.txt"), {
          "WAD"     => wad_name,
          "Level"   => demo['level'],
          "Category"=> demo['category'],
          "Players" => Array(demo['players']).join(", "),
          "Engine"  => demo['engine'],
          "TAS"     => demo['tas'].to_s,
          "Time"    => demo['time'],
          "URL"     => "https://dsdarchive.com/wads/#{short}"
        })

        FileUtils.rm_rf(merged_demo_folder) if force && Dir.exist?(merged_demo_folder)

        # Move fresh demo folders into place; merge only when the destination already exists.
        merge_result = DSDA.merge_demo_dir(temp_demo_folder, merged_demo_folder)
        if merge_result == :moved
          puts "📝 Saved demo: #{DSDA.display_path(merged_demo_folder)}"
        else
          puts "🔀 Merged demo: #{DSDA.display_path(merged_demo_folder)}"
        end
        puts green("✅ Demo extraction successful")
        puts

        state['done_demos'][demo_id.to_s] = "ok"
        DSDA.save_state(state, DSDA.state_cache_path)
      rescue => e
        puts red("❌ Demo extraction failed: #{zip_name}")
        puts "   #{e}"
        state['failed_demos'][demo_id.to_s] = "extract_error:#{e}"
        DSDA.save_state(state, DSDA.state_cache_path)
        # keep tmp_zip for inspection
        puts
      ensure
        # Always clean up temp folder
        FileUtils.rm_rf(temp_demo_folder) if Dir.exist?(temp_demo_folder)
      end
    end
  end
end

# Main entry:
if index.nil?
  puts "❌ No index cache to drive sync. Run: ruby dsda-index.rb --threads 5"
  exit 1
end

raw_query = ARGV[0]&.strip
targets =
  if options[:retry_failed]
    failed_wads = state.fetch('failed_wads', {})
    failed_demos = state.fetch('failed_demos', {})

    if failed_wads.empty? && failed_demos.empty?
      puts "No failed WADs or demos to retry."
      exit 0
    end

    if failed_wads.any?
      puts "🔁 Retrying #{failed_wads.size} failed WAD#{'s' if failed_wads.size != 1}..."
    end

    failed_wads.keys.map { |wad_slug| { wad: wad_slug } }
  else
    select_sync_targets(raw_query, index)
  end
processed = 0
errors = 0
sync_start = Time.now

puts "🎯 Sync targets: #{targets.size}"

total_targets = targets.size

targets.each_with_index do |target, target_index|
  wad_short = target[:wad]
  demos = index['wad_map'][wad_short] || []
  completed = target_index
  percent = (completed.to_f / [total_targets, 1].max * 100)
  percent_str = percent.to_i == percent ? percent.to_i.to_s : percent.round(1).to_s
  remaining = total_targets - completed

  begin
    puts orange("\n----------------------------------------------------------------------")
    puts orange("🟠 Sync progress: #{remaining} WAD#{'s' if remaining != 1} left (#{percent_str}%)")
    puts "\n────────────────────────────────────────"
    puts "Syncing wad: #{wad_short} (#{demos.length} indexed demos)"
    sync_single_wad(
      wad_short,
      state: state,
      force: options[:force],
      skip_wads: options[:skip_wads],
      skip_demos: options[:skip_demos],
      wad_meta: target[:meta]
    )
    state['failed_wads'].delete(wad_short)
  rescue Interrupt
    puts "\n✋ Interrupted by user. State saved."
    DSDA.save_state(state, DSDA.state_cache_path)
    exit
  rescue => e
    errors += 1
    puts "⚠️  Skipping wad #{wad_short} due to error: #{e.message}"
    state['failed_wads'][wad_short] = {
      'error' => e.message,
      'updated_at' => Time.now.utc.iso8601
    }
    DSDA.save_state(state, DSDA.state_cache_path)
  end
  processed += 1
end

if options[:retry_failed] && state.fetch('failed_demos', {}).any?
  DSDA.retry_failed_demos(state: state, force: options[:force])
end

state['last_sync'] = Time.now.utc.iso8601
DSDA.save_state(state, DSDA.state_cache_path)
summary = "#{errors.zero? ? '✅' : '❌'} Sync complete. Wads processed: #{processed}, errors: #{errors}"
puts "\n#{errors.zero? ? green(summary) : red(summary)}"
puts "⏱️ Time elapsed: #{format_duration(Time.now - sync_start)}"
