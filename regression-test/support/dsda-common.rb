# frozen_string_literal: true
# spec/lib/dsda_common.rb
require 'net/http'
require 'uri'
require 'json'
require 'fileutils'
require 'time'
require 'rbconfig'
require 'thread'

module DSDA
  DSDA_API = "https://dsdarchive.com/api"
  USER_AGENT = "NYAN-DSDA-SYNC/1.0"
  PER_PAGE = 200

  # caches/state paths
  def self.state_cache_path(base_dir = __dir__ + '/..')
    File.expand_path('cache/dsda_sync_state.json', base_dir)
  end

  def self.test_state_path(base_dir = __dir__ + '/..')
    File.expand_path('cache/dsda_test_state.json', base_dir)
  end

  def self.index_cache_path(base_dir = __dir__ + '/..')
    File.expand_path('cache/dsda_demo_index.json', base_dir)
  end

  def self.sync_warning_path(base_dir = __dir__ + '/..')
    File.expand_path('dsda-sync-warning.txt', base_dir)
  end

  def self.demo_root_path(base_dir = __dir__ + '/..')
    File.expand_path('support/demos', base_dir)
  end

  def self.display_path(path, base_dir = demo_root_path)
    absolute_path = File.expand_path(path.to_s)
    absolute_base = File.expand_path(base_dir.to_s)
    normalized_path = absolute_path.tr('\\', '/')
    normalized_base = absolute_base.tr('\\', '/').sub(%r{/+\z}, '')

    if normalized_path.downcase == normalized_base.downcase
      '/'
    elsif normalized_path.downcase.start_with?("#{normalized_base.downcase}/")
      "/#{normalized_path[(normalized_base.length + 1)..]}"
    else
      path.to_s.tr('\\', '/')
    end
  end

  # engines to skip
  SKIP_ENGINE_PATTERNS = [
    /gzdoom/i, /zdoom/i, /lzdoom/i, /doom\s*legacy/i,
    /vbdoom/i, /doom64ex/i, /k8vavoom/i, /qdoom/i,
    /eternity\s*engine/i
  ]

  JSON_MUTEX = Mutex.new
  INDEX_WRITE_MUTEX = Mutex.new
  HELP_FLAGS = %w[-h --h -help --help].freeze
  FAILED_FLAGS = %w[--retry-failed --failed-only].freeze

  # ============================================================
  # Time format
  # ============================================================

  def format_duration(seconds)
    hours,   rem  = seconds.divmod(3600)
    minutes, secs = rem.divmod(60)

    if hours >= 1
      # Format: H:MM:SS  (e.g. 1:23:08)
      "#{hours.to_i}:#{minutes.to_i.to_s.rjust(2,'0')}:#{secs.round.to_i.to_s.rjust(2,'0')}"
    elsif minutes >= 1
      # Format: M:SS  (e.g. 12:07)
      "#{minutes.to_i}:#{secs.round.to_i.to_s.rjust(2,'0')}"
    else
      # Format: X.X seconds
      "#{secs.round(1)} seconds"
    end
  end

  # ============================================================
  # Color helpers
  # ============================================================

  def color(text, code) "\e[#{code}m#{text}\e[0m" end
  def green(text) color(text, 32) end
  def yellow(text) color(text, 33) end
  def red(text) color(text, 31) end
  def orange(text) color(text, "38;5;208") end   # 208 is a bright orange in many terminals

  def rainbow(str, offset: 0, span: 200)
    (0...str.length).map do |i|
      # hue range from red (0°) to light blue (~200°)
      hue = (offset + ((i.to_f / [str.length - 1, 1].max) * span)) % 360
      rgb = hsv_to_rgb(hue, 1.0, 1.0)
      color_code = rgb_to_ansi256(*rgb)
      "\e[38;5;#{color_code}m#{str[i]}\e[0m"
    end.join
  end

  def hsv_to_rgb(h, s, v)
    c = v * s
    x = c * (1 - ((h / 60.0) % 2 - 1).abs)
    m = v - c

    r, g, b =
      case h
      when 0...60     then [c, x, 0]
      when 60...120   then [x, c, 0]
      when 120...180  then [0, c, x]
      when 180...240  then [0, x, c]
      else [c, 0, x]
      end

    [((r + m) * 255).round, ((g + m) * 255).round, ((b + m) * 255).round]
  end

  def rgb_to_ansi256(r, g, b)
    # approximate RGB to 256-color palette
    16 + (36 * (r / 51)) + (6 * (g / 51)) + (b / 51)
  end

  def help_flag?(arg)
    HELP_FLAGS.include?(arg.to_s.downcase)
  end

  def normalize_help_flags!(args)
    args.map! { |arg| help_flag?(arg) ? '--help' : arg }
  end

  def failed_flag?(arg)
    FAILED_FLAGS.include?(arg.to_s.downcase)
  end

  module_function :format_duration, :color, :green, :yellow, :red, :orange, :rainbow, :hsv_to_rgb, :rgb_to_ansi256, :help_flag?, :normalize_help_flags!

  def self.json_generate_safe(obj)
    JSON_MUTEX.synchronize { JSON.generate(obj) }
  end

  def self.save_index(wad_map, per: PER_PAGE, path: index_cache_path, wad_meta: {})
    INDEX_WRITE_MUTEX.synchronize do
      header = {
        'indexed_at' => Time.now.utc.iso8601,
        'per'        => per,
        'format'     => 'ndjson-v2'
      }

      dir = File.dirname(path)
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

      tmp = "#{path}.tmp"
      File.open(tmp, "w") do |f|
        # write header (compact JSON)
        f.puts(json_generate_safe(header))

        wad_meta.each do |wad, meta|
          f.puts(json_generate_safe({ "wad" => wad, "wad_meta" => meta }))
        end

        # write demo lines (compact JSON)
        wad_map.each do |wad, demos|
          demos.each do |demo|
            f.puts(json_generate_safe({ "wad" => wad, "demo" => demo }))
          end
        end
      end

      # Atomic replace
      File.rename(tmp, path)
    end
  end

  def self.json_parse_safe(str)
    JSON_MUTEX.synchronize do
      JSON.parse(str)
    end
  end

  def self.json_dump_safe(obj)
    JSON_MUTEX.synchronize do
      JSON.pretty_generate(obj)
    end
  end

  def self.atomic_write(path, content)
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
    tmp = "#{path}.tmp"
    File.write(tmp, content)
    File.rename(tmp, path)
  end

  def self.safe_name(s)
    s.to_s.strip.gsub(/[^\w\-.]+/,'_')
  end

  def self.engine_should_skip?(engine)
    return false if engine.nil? || engine.to_s.strip.empty?
    SKIP_ENGINE_PATTERNS.any? { |pat| engine =~ pat }
  end

  def self.excluded_demo_zip_reason(iwad:, wad:, zip_name:, demo_id: nil, zip_url: nil)
    return nil unless Object.const_defined?(:EXCLUDED_DEMO_ZIPS)

    exclusions = Object.const_get(:EXCLUDED_DEMO_ZIPS)
    return nil unless exclusions.respond_to?(:each)

    normalized = {}
    exclusions.each do |key, reason|
      normalized[key.to_s.downcase] = reason.to_s
    end

    candidates = [
      "#{iwad}/#{wad}/#{zip_name}",
      "#{wad}/#{zip_name}",
      zip_name,
      demo_id && "demo:#{demo_id}",
      zip_url
    ].compact.map { |value| value.to_s.downcase }

    match = candidates.find { |candidate| normalized.key?(candidate) }
    match ? normalized[match] : nil
  end

  def self.detect_7z
    host_os = RbConfig::CONFIG['host_os'].downcase
    candidates = if host_os =~ /mswin|mingw|cygwin/
      ['C:\\Program Files\\7-Zip\\7z.exe','C:\\Program Files (x86)\\7-Zip\\7z.exe','7z']
    else
      ['7zz','7z','/usr/local/bin/7z','/opt/homebrew/bin/7z']
    end
    candidates.map(&:to_s).map{|p| p.strip.gsub('"','') }.find do |p|
      if %w[7z 7zz].include?(p)
        (system("which #{p} >7z.log 2>&1") rescue false)
      else
        File.exist?(p)
      end
    end
  end

  SEVEN_ZIP = detect_7z
  unless SEVEN_ZIP
    raise "7z not found. Install 7-Zip or p7zip and ensure `7z`/`7zz` is on PATH."
  end
  SEVEN_ZIP_BIN = %Q["#{SEVEN_ZIP}"]

  def self.http_get_json(url)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = USER_AGENT
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
      res = http.request(req)
      if res.code.to_i == 200
        begin
          return json_parse_safe(res.body)
        rescue JSON::ParserError => e
          raise "JSON parse error for #{url} → maybe HTML (#{e.message})"
        end
      else
        raise "HTTP #{res.code} for #{url}"
      end
    end
  end

  def self.write_dsda_info(path, map)
    FileUtils.mkdir_p(File.dirname(path)) unless Dir.exist?(File.dirname(path))

    File.open(path, 'w') do |f|
      f.puts "[DSDA INFO]"
      map.each do |k, v|
        f.puts "#{k}: #{v}"
      end
    end
  end

  def self.http_head_size(url)
    return nil if url.nil? || url.to_s.strip.empty?
    uri = URI(url)
    req = Net::HTTP::Head.new(uri)
    req['User-Agent'] = USER_AGENT
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
      res = http.request(req)
      return res['content-length']&.to_i if res.code.to_i == 200
    end
  rescue
    nil
  end

  def self.download_file(url, dest)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme=='https') do |http|
      http.request_get(uri.path + (uri.query ? "?#{uri.query}" : "")) do |resp|
        unless resp.is_a?(Net::HTTPSuccess)
          raise "HTTP #{resp.code} while downloading #{url}"
        end

        File.open(dest, "wb") do |io|
          resp.read_body { |chunk| io.write(chunk) }
        end
      end
    end
  end

  def self.retry_failed_demos(state:, force: false)
    failed = state["failed_demos"] || {}
    return puts "No failed demos to retry." if failed.empty?

    puts "🔁 Retrying #{failed.size} failed demos..."

    # Group failed demo IDs by WAD
    wad_groups = Hash.new { |h,k| h[k] = [] }

    failed.keys.each do |demo_id|
      # fetch metadata to recover wad + zip
      begin
        meta = http_get_json("#{DSDA_API}/demos/#{demo_id}")
      rescue => e
        puts "❌ Cannot fetch demo #{demo_id} metadata: #{e.message}"
        next
      end

      wad = meta["wad"].to_s
      wad_groups[wad] << [demo_id, meta]
    end

    wad_groups.each do |wad, entries|
      puts "\n🔄 Retrying wad=#{wad} (#{entries.size} demos)"

      wad_meta = http_get_json("#{DSDA_API}/wads/#{URI.encode_www_form_component(wad)}")
      short = wad_meta["short_name"] || wad
      iwad  = wad_meta["iwad"] || "doom2"

      wad_root = File.join(File.expand_path("..", __dir__), "support/demos", iwad, short)
      FileUtils.mkdir_p(wad_root)

      entries.each do |demo_id, meta|
        zip_url = meta["file"].to_s.sub(/^http:/, "https:")
        zip_name = File.basename(zip_url) rescue "#{demo_id}.zip"
        demo_base = File.basename(zip_name, ".zip")

        puts "   ↻ demo #{demo_id}"

        if reason = excluded_demo_zip_reason(iwad: iwad, wad: short, zip_name: zip_name, demo_id: demo_id, zip_url: zip_url)
          puts "     ⚠️ skipping excluded zip: #{zip_name} (#{reason})"
          state["done_demos"][demo_id.to_s] = "skipped_zip:#{zip_name}"
          state["failed_demos"].delete(demo_id.to_s)
          save_state(state, state_cache_path)
          puts
          next
        end

        puts "     ⬇️ retry downloading..."

        tmp_zip = File.join(wad_root, zip_name)
        demo_folder = File.join(wad_root, "#{demo_id}_#{demo_base}")

        FileUtils.rm_rf(demo_folder) if force && Dir.exist?(demo_folder)
        FileUtils.mkdir_p(demo_folder)

        begin
          download_file(zip_url, tmp_zip)
        rescue => e
          puts red("     ❌ Demo download failed: #{zip_name}")
          puts "        #{e.message}"
          puts
          next
        end

        begin
          extract_with_7z(tmp_zip, demo_folder)
          cleanup_unwanted_files(demo_folder)
          File.delete(tmp_zip) if File.exist?(tmp_zip)
        rescue => e
          puts red("     ❌ Demo extraction failed: #{zip_name}")
          puts "        #{e.message}"
          puts
          next
        end

        puts green("     ✅ Demo extraction successful")
        puts
        state["done_demos"][demo_id.to_s] = "ok"
        state["failed_demos"].delete(demo_id.to_s)
      end
    end
  end

  def self.extract_with_7z(zip_path, dest)
    FileUtils.mkdir_p(dest)
    cmd = "#{SEVEN_ZIP_BIN} x \"#{zip_path}\" -o\"#{dest}\" -y >7z.log 2>&1"
    puts "📂 Extracting #{File.basename(zip_path)} → #{display_path(dest)} (via 7-Zip)"
    unless system(cmd)
      extracted_count = extracted_file_count(dest)
      if extracted_count.positive?
        puts "⚠️  7-Zip reported errors, but #{extracted_count} file#{'s' if extracted_count != 1} were extracted; keeping them."
        append_sync_warning(zip_path, dest, extracted_count)
        return :partial
      end

      raise "Extraction failed for #{zip_path}"
    end
    puts "🧰 Extracted successfully."
    :ok
  end

  def self.extracted_file_count(dir)
    Dir.glob(File.join(dir, '**', '*'), File::FNM_DOTMATCH).count { |path| File.file?(path) }
  end

  def self.append_sync_warning(zip_path, dest, extracted_count, path = sync_warning_path)
    FileUtils.mkdir_p(File.dirname(path))
    log = File.exist?('7z.log') ? File.read('7z.log', mode: 'rb').encode('UTF-8', invalid: :replace, undef: :replace) : '(7z.log not found)'

    File.open(path, 'a') do |f|
      f.puts "----------------------------------------------------------------------"
      f.puts "Time: #{Time.now.utc.iso8601}"
      f.puts "ZIP: #{zip_path}"
      f.puts "Destination: #{dest}"
      f.puts "Extracted files: #{extracted_count}"
      f.puts
      f.puts "7-Zip returned an error, but files were extracted. Sync kept the extracted files and continued."
      f.puts
      f.puts "[7z.log]"
      f.puts log
      f.puts
    end

    puts "📝 Sync warning logged to #{path}"
  end

  def self.cleanup_unwanted_files(dir)
    Dir.glob(File.join(dir,'**','*.exe')).each do |f|
      begin
        File.delete(f)
        puts "🧹 Removed EXE: #{f}"
      rescue => e
        puts "⚠️ Could not delete #{f}: #{e.message}"
      end
    end
  end

  def self.content_present?(dir)
    ['**/*.wad','**/*.lmp','**/*.deh','**/*.bex','**/*.txt'].any? { |g| Dir.glob(File.join(dir,g)).any? }
  end

  # state helpers
  def self.load_selected_port
    ports = Object.const_get(:PORTS)
    default_port = Object.const_get(:DEFAULT_PORT)
    path = Object.const_get(:PORT_STATE_PATH)
    return default_port unless File.file?(path)

    state = JSON.parse(File.read(path))
    return default_port unless state.is_a?(Hash)

    saved = state.fetch('port', state.fetch('port_profile', '')).to_s.downcase
    ports.key?(saved) ? saved : default_port
  rescue JSON::ParserError, SystemCallError
    default_port
  end

  def self.save_selected_port(name)
    path = Object.const_get(:PORT_STATE_PATH)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate({ 'port' => name }))
  end

  def self.load_state(path = state_cache_path)
    default = { "last_sync" => nil, "done_wads" => {}, "done_demos" => {}, "failed_wads" => {}, "failed_demos" => {}, "wad_meta" => {} }
    return default unless File.exist?(path)

    begin
      default.merge(json_parse_safe(File.read(path)))
    rescue => _
      default
    end
  end

  def self.save_state(state, path = state_cache_path)
    atomic_write(path, json_dump_safe(state))
  end

  # index helpers
  def self.load_index(path = index_cache_path)
    return nil unless File.exist?(path)

    raw = File.read(path)
    return nil if raw.strip.empty?

    lines = raw.lines

    # --- DETECT FORMATS ------------------------------------------------------

    # Case 1: Old JSON index (single JSON object)
    # Heuristic: entire file starts with { AND ends with }
    # AND contains "wad_map" INSIDE the object.
    if lines.length == 1 && raw.lstrip.start_with?("{") && raw.rstrip.end_with?("}")
      begin
        warn "ℹ️ Converting old JSON index → NDJSON format..."
        data = json_parse_safe(raw)
        wad_map = data["wad_map"]

        if wad_map.is_a?(Hash)
          save_index(wad_map, per: data["per"], path: path, wad_meta: data["wad_meta"] || {})
          return load_index(path)
        else
          warn "⚠️ 'wad_map' missing in old JSON format"
          return nil
        end
      rescue => e
        warn "⚠️ Old JSON index is corrupt: #{e.message}"
        return nil
      end
    end

    # Case 2: NDJSON format (1 header + many demo lines)
    # NDJSON ALWAYS has ≥2 lines.
    if lines.length >= 2
      begin
        header = json_parse_safe(lines[0])
        return nil unless header.is_a?(Hash) && header["indexed_at"]

        wad_map = Hash.new { |h,k| h[k] = [] }
        wad_meta = {}

        lines[1..].each_with_index do |line, idx|
          stripped = line.strip
          next if stripped.empty?
          next unless stripped.start_with?("{")   # skip garbage or accidental text

          begin
            obj = json_parse_safe(stripped)
          rescue => e
            warn "⚠️ NDJSON parse error on line #{idx+2}: #{e.message}"
            next
          end

          wad = obj["wad"]
          next if wad.nil?

          if obj.key?("wad_meta")
            wad_meta[wad] = obj["wad_meta"] || {}
            next
          end

          demo = obj["demo"]
          next if demo.nil?

          wad_map[wad] << demo
        end

        return {
          "indexed_at" => header["indexed_at"],
          "per"        => header["per"],
          "format"     => header["format"],
          "wad_map"    => wad_map,
          "wad_meta"   => wad_meta
        }
      rescue => e
        warn "⚠️ NDJSON index parse error: #{e.message}"
        return nil
      end
    end

    warn "⚠️ Unrecognized index format — ignoring."
    nil
  end

  # fast index function (can be multi-threaded)
  def self.fast_index_all_pages(total_pages, threads: 5, max_retries: 5, per: PER_PAGE)
    wad_map = Hash.new { |h,k| h[k] = [] }
    mutex   = Mutex.new
    completed_pages = 0
    work_q  = Queue.new
    (1..total_pages).each { |p| work_q << [p, 0] }   # [page, attempts]

    workers = Array.new(threads) do
      Thread.new do
        loop do
          begin
            page, attempt = work_q.pop(true)
          rescue ThreadError
            break
          end

          url = page == 1 ? "#{DSDA_API}/demos?per=#{per}" : "#{DSDA_API}/demos?per=#{per}&page=#{page}"
          begin
            data = http_get_json(url)
          rescue => e
            puts "❌ Page #{page} failed (attempt #{attempt+1}/#{max_retries}): #{e.message}"
            if attempt + 1 < max_retries
              sleep(0.3 * (attempt + 1))
              work_q << [page, attempt + 1]
            else
              puts "🚫 Page #{page} permanently failed after #{max_retries} attempts."
            end
            next
          end

          demos = data["demos"]
          if demos.nil? || demos.empty?
            puts "⚠️ Page #{page} returned empty result"
            next
          end

          mutex.synchronize do
            demos.each { |d| wad_map[d["wad"].to_s] << d }
            completed_pages += 1
            percent = (completed_pages.to_f / [total_pages, 1].max * 100)
            percent_str = percent.to_i == percent ? percent.to_i.to_s : percent.round(1).to_s
            puts "  page #{page} ✓ #{completed_pages}/#{total_pages} (#{demos.length} demos - #{percent_str}%)"
          end
        end
      end
    end

    workers.each(&:join)
    wad_map
  end

  def self.fetch_wad_meta_map(wad_slugs, threads: 8, max_retries: 5)
    wad_meta = {}
    total = wad_slugs.length
    completed = 0
    mutex = Mutex.new
    work_q = Queue.new
    wad_slugs.each { |wad| work_q << [wad, 0] }

    workers = Array.new(threads) do
      Thread.new do
        loop do
          begin
            wad, attempt = work_q.pop(true)
          rescue ThreadError
            break
          end

          begin
            meta = http_get_json("#{DSDA_API}/wads/#{URI.encode_www_form_component(wad)}")
          rescue => e
            if attempt + 1 < max_retries
              sleep(0.3 * (attempt + 1))
              work_q << [wad, attempt + 1]
            else
              mutex.synchronize do
                completed += 1
                puts "  wad metadata #{completed}/#{total} failed: #{wad} (#{e.message})"
              end
            end
            next
          end

          clean_meta = {
            "short_name" => meta["short_name"] || wad,
            "name"       => meta["name"],
            "iwad"       => meta["iwad"] || "doom2",
            "id"         => meta["id"],
            "file"       => meta["file"],
            "author"     => meta["author"],
            "authors"    => meta["authors"],
            "description"=> meta["description"]
          }

          mutex.synchronize do
            wad_meta[wad] = clean_meta
            completed += 1
            percent = (completed.to_f / [total, 1].max * 100).round(1)
            puts "  wad metadata #{completed}/#{total} (#{percent}%)" if completed == total || (completed % 25).zero?
          end
        end
      end
    end

    workers.each(&:join)
    wad_meta
  end

  # For LMP conflict: if same name but different size, generate new name
  # foo.lmp → foo_2.lmp → foo_3.lmp etc.
  def self.next_available_filename(dest_dir, base)
    ext  = File.extname(base)
    stem = File.basename(base, ext)
    name = base
    counter = 2

    while File.exist?(File.join(dest_dir, name))
      name = "#{stem}_#{counter}#{ext}"
      counter += 1
    end

    name
  end

  # Merge temporary extracted demo folder into the final merged folder.
  # Keep every extracted demo-side file, while appending DSDA-info.txt blocks.
  def self.merge_demo_dir(src, dest)
    unless Dir.exist?(dest)
      FileUtils.mv(src, dest)
      return :moved
    end

    src_prefix = File.join(src, '')

    Dir.glob(File.join(src, '**', '*'), File::FNM_DOTMATCH).each do |file|
      next unless File.file?(file)
      next if File.basename(file).casecmp?('DSDA-info.txt')

      relative = file.sub(/\A#{Regexp.escape(src_prefix)}/, '')
      dest_file = File.join(dest, relative)
      FileUtils.mkdir_p(File.dirname(dest_file))

      base = File.basename(file)
      if File.exist?(dest_file)
        # identical size → assume duplicate; skip
        if File.size(file) == File.size(dest_file)
          next
        else
          # conflict → rename incoming file in the same relative folder
          new_name = next_available_filename(File.dirname(dest_file), base)
          new_relative = File.join(File.dirname(relative), new_name)
          puts "      ⚠️ Conflict: #{relative} → #{new_relative}"
          FileUtils.cp(file, File.join(File.dirname(dest_file), new_name))
        end
      else
        FileUtils.cp(file, dest_file)
      end
    end

    src_info = File.join(src, "DSDA-info.txt")
    if File.exist?(src_info)
      dest_info = File.join(dest, "DSDA-info.txt")
      if File.exist?(dest_info)
        File.open(dest_info, "a") do |f|
          f.puts "\n\n" + File.read(src_info)
        end
      else
        FileUtils.cp(src_info, dest_info)
      end
    end

    :merged
  end
end
