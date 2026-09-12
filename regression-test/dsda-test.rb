#!/usr/bin/env ruby
# frozen_string_literal: true

require 'stringio'
require 'fileutils'
require 'csv'
require 'open3'
require 'timeout'
require 'parallel'
require 'tempfile'
require 'rbconfig'
require 'io/wait'
require 'pathname'
require 'securerandom'
require 'json'
require_relative 'support/dsda-common'
require_relative 'support/dsda-test-prefs'
require_relative 'support/dsda-port-prefs'
include DSDA

def print_help
  puts <<~HELP
    Usage:
      ruby dsda-test.rb [IWAD[/WAD[/DEMO_FOLDER]]] [options]

    Selectors:
      ruby dsda-test.rb
      ruby dsda-test.rb --all
      ruby dsda-test.rb doom2
      ruby dsda-test.rb doom2/av
      ruby dsda-test.rb doom2/av/av01-123
      ruby dsda-test.rb av
      ruby dsda-test.rb av/av01-123

    Options:
      --all
          Run all IWADs, including Heretic, Hexen, and Chex.

      --retry-failed, --failed-only
          Re-run demos listed in failures.csv only.

      --fill-demo-folder
          Fill missing DemoFolder values in overrides.csv and exit.

      --set-exe-path PATH
          Override the new engine executable for this run.

      --set-old-exe-path PATH
          Override the old/reference engine executable for this run.

      --port NAME
          Select a configured port by its name or nickname.

      --port-name NAME
          Override only the port name recorded in the saved test summary.

      --compare
          Run the old/reference engine even when the new engine passes, then compare levelstat output.

      --complevel NUMBER, --cl NUMBER
          Run only demos whose DSDA-info.txt Port (or legacy Engine) value ends in cl#.
          For example, --complevel 2 and --cl 2 match cl2 but not cl21.

      -h, --h, -help, --help
          Show this help.
  HELP
end

if ARGV.any? { |arg| DSDA.help_flag?(arg) }
  print_help
  exit 0
end

def consume_path_option!(names)
  index = ARGV.index { |arg| names.include?(arg) }
  return nil unless index

  value = ARGV[index + 1]
  abort("❌ Missing value for #{ARGV[index]}") if value.nil? || value.start_with?("--")

  ARGV.slice!(index, 2)
  File.expand_path(value)
end

def consume_value_option!(names)
  index = ARGV.index { |arg| names.include?(arg) }
  return nil unless index

  value = ARGV[index + 1]
  abort("❌ Missing value for #{ARGV[index]}") if value.nil? || value.start_with?("--")

  ARGV.slice!(index, 2)
  value
end

exe_path_override = consume_path_option!(%w[--set-exe-path])
old_exe_path_override = consume_path_option!(%w[--set-old-exe-path])
port_option = consume_value_option!(%w[--port])
port_name_option = consume_value_option!(%w[--port-name])
complevel_filter_value = consume_value_option!(%w[--complevel --cl])

selected_port_name = DSDA.load_selected_port
if port_option
  requested_port = port_option.strip.downcase
  selected_port_name =
    if PORTS.key?(requested_port)
      requested_port
    else
      PORTS.find { |_name, port| port[:nickname].to_s.downcase == requested_port }&.first
    end

  abort("❌ Unknown port: #{port_option.inspect}") unless selected_port_name
  begin
    DSDA.save_selected_port(selected_port_name)
  rescue SystemCallError => e
    warn("⚠️ Could not remember port: #{e.message}")
  end
end

if complevel_filter_value && complevel_filter_value !~ /\A\d+\z/
  abort("❌ Invalid complevel: #{complevel_filter_value.inspect} (expected a number)")
end

RUN_ALL_IWADS = ARGV.delete("--all") ? true : false
LEVELSTAT_COMPARE = ARGV.delete("--compare") ? true : false
FAILED_ONLY = ARGV.any? { |arg| DSDA.failed_flag?(arg) }
COMPLEVEL_FILTER = complevel_filter_value&.to_i

# Throw an error if command is not recognised
# If it's the same flag but slightly off show a message like:
# "Did you mean `--compare`?" when typing `-compare`.
remaining_flags = ARGV.select { |arg| arg.start_with?("-") }
recognized_remaining_flags = DSDA::FAILED_FLAGS + %w[--fill-demo-folder]
unknown_flags = remaining_flags.reject { |arg| recognized_remaining_flags.include?(arg.downcase) }

unless unknown_flags.empty?
  flag = unknown_flags.first
  double_dash = "--#{flag.delete_prefix('-')}"
  known_flags = %w[
    --all --compare --retry-failed --failed-only --fill-demo-folder
    --set-exe-path --set-old-exe-path --port --port-name --complevel --cl
  ]
  suggestion = known_flags.include?(double_dash.downcase) ? " Did you mean #{double_dash}?" : ""
  abort("❌ Unknown option: #{flag}.#{suggestion} Run with --help for usage.")
end

TEST_SCOPE_LABEL = begin
  query = ARGV.find { |arg| !arg.start_with?("-") }&.strip
  if FAILED_ONLY
    "failed-only"
  elsif RUN_ALL_IWADS
    "all"
  elsif query && !query.empty?
    query
  else
    "primary"
  end
end

selected_port = PORTS[selected_port_name]

if selected_port || exe_path_override
  Object.send(:remove_const, :EXE_PATH)
  EXE_PATH = exe_path_override || selected_port.fetch(:exe)
end

if selected_port || old_exe_path_override
  Object.send(:remove_const, :OLD_EXE_PATH)
  OLD_EXE_PATH = old_exe_path_override || selected_port.fetch(:old_exe)
end

TEST_PORT_NAME = begin
  configured_name = PORTS.find do |_name, port|
    File.expand_path(port.fetch(:exe)).casecmp?(File.expand_path(EXE_PATH))
  end&.first

  if !port_name_option.to_s.strip.empty?
    port_name_option.strip
  else
    selected_port_name || configured_name || File.basename(EXE_PATH, File.extname(EXE_PATH))
  end
end

# ============================================================
# Helpers
# ============================================================

def q(s)
  %Q{"#{s}"}
end

def auto_quote_rule(v)
  return "" if v.nil?
  s = v.to_s
  s.start_with?("0") ? "\"#{s}\"" : s
end

def strip_manual_quotes(v)
  return nil if v.nil?
  s = v.to_s.strip

  # Excel-friendly CSV values can come back as literal quotes ("01fava")
  # or as formulas such as ="01fava". Runtime matching should see 01fava.
  if s.start_with?("=")
    formula_value = s[1..].to_s.strip
    s = formula_value if formula_value.start_with?('"') && formula_value.end_with?('"')
  end

  while s.length >= 2 && s.start_with?('"') && s.end_with?('"')
    s = s[1...-1].strip
  end

  s
end

def safe_str(str)
  return "" unless str
  str.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
rescue
  ""
end

def find_child_ci(dir, name)
  return nil if dir.nil? || name.nil?
  exact = File.join(dir, name)
  return exact unless Dir.exist?(dir)

  children = Dir.children(dir)
  child = children.find { |entry| entry == name } ||
          children.find { |entry| entry.casecmp?(name) }

  child ? File.join(dir, child) : (File.exist?(exact) ? exact : nil)
rescue SystemCallError
  nil
end

def resolve_path_ci(base, relative)
  return nil if base.nil? || relative.nil?
  return relative if Pathname.new(relative.to_s).absolute? && File.exist?(relative)
  return nil unless Dir.exist?(base)

  current = base
  relative.to_s.split(/[\/\\]+/).reject(&:empty?).each do |part|
    current = find_child_ci(current, part)
    return nil unless current
  end

  current
end

def files_with_ext_ci(dir, *extensions, recursive: false)
  return [] unless Dir.exist?(dir)

  wanted = extensions.flatten.map do |ext|
    ext = ext.to_s.downcase
    ext.start_with?('.') ? ext : ".#{ext}"
  end

  results = []
  stack = [dir]

  until stack.empty?
    current = stack.pop
    Dir.children(current).each do |entry|
      path = File.join(current, entry)
      if File.directory?(path)
        stack << path if recursive
      elsif wanted.include?(File.extname(entry).downcase)
        results << path
      end
    end
  end

  results.sort
rescue SystemCallError
  []
end

def crash_message?(status)
  return nil unless status # sanity check

  code = status.exitstatus
  return nil if code == 0   # normal exit

  "💥💥💥 DEMO CRASHED 💥💥💥 (exit #{code})"
end

def normalize_demo_relative_paths_old(paths, demo_path)
  return [] if paths.nil? || paths.empty?

  # demo_path = .../<iwad>/<wadfolder>/<demo_folder>/<demo.lmp>
  demo_folder = File.dirname(demo_path)
  wadfolder_path = File.dirname(demo_folder)

  paths.map do |path|
    # Strip everything up through the wadfolder directory
    rel = path.sub(/^#{Regexp.escape(wadfolder_path)}[\/\\]?/, '')

    rel.gsub(/^[\/\\]/, '')  # remove accidental leading slash
  end
end

def normalize_demo_relative_paths(paths, demo_path)
  return [] if paths.nil? || paths.empty?

  demo_folder     = File.dirname(demo_path)
  wadfolder_path  = File.dirname(demo_folder)

  # The real wadfolder containing files is "<wadname>-wad"
  pwad_folder_name = File.basename(wadfolder_path) + "-wad"

  paths.map do |path|
    norm_path = path.tr("\\", "/")
    norm_demo = demo_folder.tr("\\", "/")
    norm_wad  = wadfolder_path.tr("\\", "/")

    # ----------------------------
    # demo_dir/* override
    # ----------------------------
    if norm_path.start_with?(norm_demo + "/")
      rel = norm_path.sub(/^#{Regexp.escape(norm_demo)}\//, "")
      next "demo_dir/#{rel}"
    end

    # ----------------------------
    # Strip wadfolder prefix
    # ----------------------------
    rel = norm_path.sub(/^#{Regexp.escape(norm_wad)}\//, "")
    rel = rel.sub(/^\//, "")

    # ----------------------------
    # Strip "<wadname>-wad/" prefix
    # ----------------------------
    if rel.start_with?(pwad_folder_name + "/")
      rel = rel.split("/", 2)[1]
    end

    rel
  end
end

def parse_dsda_time_to_seconds(str)
  return nil unless str
  s = str.strip

  # --- H:MM:SS(.xx) ---
  if s =~ /^(\d+):(\d{2}):(\d{2})(?:\.(\d+))?$/
    h, m, sec = $1.to_i, $2.to_i, $3.to_i
    return h * 3600 + m * 60 + sec
  end

  # --- M:SS(.xx) or MM:SS without ms ---
  if s =~ /^(\d+):(\d{2})(?:\.(\d+))?$/
    m, sec = $1.to_i, $2.to_i
    return m * 60 + sec
  end

  nil
end

def seconds_to_dsda_format(sec)
  return "" unless sec
  sec = sec.to_i

  h, rem = sec.divmod(3600)
  m, s   = rem.divmod(60)

  if h > 0
    "%d:%02d:%02d" % [h, m, s]
  else
    "%d:%02d" % [m, s]
  end
end

def extract_expected_times(demo_folder_path)
  info_path = find_child_ci(demo_folder_path, "DSDA-info.txt")
  return [] unless info_path && File.exist?(info_path)

  text = File.read(info_path, encoding: 'UTF-8')
  times = []

  text.scan(/Time:\s*([0-9:\.]+)/i) do |m|
    sec = parse_dsda_time_to_seconds(m[0])
    times << sec if sec
  end

  times.uniq
end

def dsda_info_complevel(demo_folder_path)
  info_path = find_child_ci(demo_folder_path, "DSDA-info.txt")
  return nil unless info_path && File.file?(info_path)

  fields = {}
  File.foreach(info_path, encoding: 'bom|utf-8') do |line|
    next unless line =~ /^\s*(Port|Engine)\s*:\s*(.*?)\s*$/i

    fields[$1.downcase] = $2
  end

  # Current metadata calls field "Port", but older downloaded metadata says "Engine"
  # So test both
  value = fields['port'] || fields['engine']
  match = value&.match(/cl(\d+)\s*\z/i)
  match && match[1].to_i
rescue SystemCallError, EncodingError
  nil
end

def sanitize_cmdline(cmd)
# 1) replace -fastdemo with -playdemo
  cmd = cmd.gsub("-fastdemo", "-playdemo")

# 2) remove the unwanted flags
  remove = %w[-nosound -nomusic -nodraw -levelstat -analysis -noautoload]
  remove.each { |flag| cmd = cmd.gsub(flag, "") }

# 3) collapse double spaces caused by removals
  cmd.gsub(/\s+/, " ").strip
end

def wait_for_file(path, timeout_secs: 2.0, interval_secs: 0.05)
  deadline = Time.now + timeout_secs

  until File.exist?(path) || Time.now >= deadline
    sleep interval_secs
  end

  File.exist?(path)
end

def detect_demo_engine_from_log(log_output)
  if log_output =~ /G_ReadDemoHeader:\s+Unknown demo format\s+(\d+)/i
    code = $1.to_i
    case code
    when 70
      return :zdoom
    when 126, 132, 140, 141, 142
      return :doom_legacy
    else
      return :"unknown_#{code}"
    end
  end
  nil
end

module Utility
  module TimeUtils
    def self.to_seconds(time_str)
      return 0 unless time_str && time_str =~ /(\d+):(\d{2})/
      $1.to_i * 60 + $2.to_i
    end
  end
end

$print_mutex = Mutex.new

def thread_log(log)
  if SINGLE_FOLDER_MODE
    # print directly (no buffering)
    msg = StringIO.new
    $stdout = msg
    yield
    $stdout = STDOUT
    text = msg.string.strip
    puts text unless text.empty?
  else
    # existing buffered logging behavior
    msg = StringIO.new
    $stdout = msg
    yield
    $stdout = STDOUT
    log << msg.string.strip unless msg.string.strip.empty?
  end
end

def log_line(log, text)
  return if text.nil? || text.empty?

  if SINGLE_FOLDER_MODE
    # direct live output
    puts text
  else
    # buffered per-thread output
    log << text
  end
end

# ============================================================
# CSV BACKUP: creates timestamped backups in per-file backup folders.
# ============================================================
def backup_csv(file_path)
  return unless File.exist?(file_path)

  bu_dir =
    case File.expand_path(file_path)
    when File.expand_path(RESULTS_OUTPUT)  then RESULTS_BACKUP_PATH
    when File.expand_path(FAILURES_OUTPUT) then FAILURES_BACKUP_PATH
    else File.join(File.dirname(file_path), "BU")
    end

  FileUtils.mkdir_p(bu_dir)

  timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
  filename  = "#{File.basename(file_path, ".csv")}-#{timestamp}.csv"
  target    = File.join(bu_dir, filename)

  FileUtils.cp(file_path, target)
  puts yellow("🗄️  Backup created: #{target}")
end

# ============================================================
# Unified result-row builder (updated for new CSV schema)
# ============================================================

def build_result_row(base:, override:, runtime:)
  {
    # -------- Needed for Overrides --------
    iwadfolder:  base[:iwadfolder],
    wadfoldername: base[:wadfoldername],
    demo_foldername: base[:demo_foldername],

    # ---------- Identity fields ----------
    iwad:        base[:iwad],              # e.g. doom2.wad
    wadfolder:   base[:wadfolder],         # e.g. av
    wad:         base[:wad],               # primary wad file (av.wad)
    deh:         base[:deh],               # "fix.deh ; extra/fix2.deh"
    demofile:    base[:demofile],          # single lmp name

    # --------- DSDA-info.txt Time ----------
    expected:     runtime[:expected],

    # ---------- NEW engine results ----------
    new_actual:   runtime[:new_actual],
    new_result:   runtime[:new_result],

    # ---------- OLD engine results ----------
    old_actual:   runtime[:old_actual],
    old_result:   runtime[:old_result],

    # ---------- Regression / metadata ----------
    match:        runtime[:match],
    action:       runtime[:action],        # override / skip / nil
    reason:       runtime[:reason],

    # Move error AFTER extras per user request
    error:        runtime[:error],

    # ---------- Override fields ----------
    iwad_override:  override&.dig(:iwad_override),
    file_override:  override&.dig(:file_override),
    extra_args:     override&.dig(:extra_args),
    comments:       override&.dig(:comments),

    # ---------- Useful for failed demos ----------
    cmdline:      runtime[:cmdline],
    demofolder:   runtime[:folderpath]
  }
end

# ============================================================
# Demo startup
# ============================================================
puts "\n"
puts ("----------------------------------------------------------------------")
puts ("🟢 Setup bulk demo regression test")

# Clean temp demos cache on startup to avoid stale data
begin
  FileUtils.rm_rf(DEMOS_CACHE_ROOT)
rescue
end

# ============================================================
# CSV Helpers
# ============================================================

def in_quotes(args)
  return "" if args.nil? || args.empty?
  # Ensure array & wrap the full string in quotes
  "\"#{Array(args).join(' ')}\""
end

def csv_next_numbered_filename(base_path)
  dirname  = File.dirname(base_path)
  basename = File.basename(base_path, ".csv")

  index = 1
  loop do
    candidate = File.join(dirname, "#{basename}-#{index}.csv")
    return candidate unless File.exist?(candidate)
    index += 1
  end
end

# ============================================================
# --failed-only support (non-invasive)
# ============================================================
ARGV.delete_if { |arg| DSDA.failed_flag?(arg) }

def load_failures_list
  return {} unless FAILED_ONLY
  return {} unless File.exist?(FAILURES_OUTPUT)

  rows = CSV.read(FAILURES_OUTPUT, headers: true)
  failures = {}

  rows.each do |row|
    iwadfolder = strip_manual_quotes(row["IwadFolder"])
    wadfolder  = strip_manual_quotes(row["WadFolder"])
    demofile   = strip_manual_quotes(row["DemoFile"])
    next if iwadfolder.nil? || wadfolder.nil? || demofile.nil?

    key = [iwadfolder.downcase, wadfolder.downcase]
    failures[key] ||= Set.new
    failures[key] << demofile.downcase
  end

  failures
end

if ARGV.include?("--fill-demo-folder")
  puts "🔧 Filling missing DemoFolder values in overrides.csv..."

  override_path = OVERRIDE_IMPORT

  rows = CSV.read(override_path, headers: true)
  headers = rows.headers

  # Add column if missing
  unless headers.include?("DemoFolder")
    headers << "DemoFolder"
  end

  updated_count = 0

  rows.each do |row|
    next if row["DemoFolder"] && !row["DemoFolder"].strip.empty?

    iwad = strip_manual_quotes(row["IwadFolder"])
    wad  = strip_manual_quotes(row["WadFolder"])
    lmp  = strip_manual_quotes(row["DemoFile"])

    demo_root = iwad && wad ? resolve_path_ci(DEMOS_ROOT, File.join(iwad, wad)) : nil
    matches =
      if demo_root && lmp
        files_with_ext_ci(demo_root, '.lmp', recursive: true)
          .select { |path| File.basename(path).casecmp?(lmp) }
      else
        []
      end

    if matches.any?
      folder = File.basename(File.dirname(matches[0]))
      row["DemoFolder"] = folder
      updated_count += 1
      puts "   ✔ #{iwad}/#{wad}/#{lmp} → DemoFolder=#{folder}"
    else
      puts "   ⚠ No match for #{iwad}/#{wad}/#{lmp} (left blank)"
      row["DemoFolder"] = ""
    end
  end

  # Write updated CSV
  CSV.open(override_path, "w", write_headers: true, headers: headers) do |csv|
    rows.each { |r| csv << r }
  end

  puts "\n✅ Done!"
  puts "   Filled #{updated_count} missing DemoFolder entries"
  puts "   Updated file: #{override_path}"
  puts "💤 Exiting now."
  exit 0
end

# ============================================================
# Fully self-contained: merge failed-only rows into results.csv
# ============================================================
def merge_failed_rows_into_results(failed_rows, results_path)
  puts "🔄 Merging failed-only results into #{results_path}..."

  # ------------------------------------------------------------
  # 1. Load existing results.csv
  # ------------------------------------------------------------
  unless File.exist?(results_path)
    puts red("❌ ERROR: 1-results.csv not found at #{results_path}")
    return
  end

  existing_rows = []
  CSV.foreach(results_path, headers: true, return_headers: false) do |row|
    begin
      existing_rows << row.to_h
    rescue => e
      warn "⚠️ Skipping malformed CSV row: #{row.inspect}\n   #{e.class}: #{e.message}"
    end
  end

  if existing_rows.empty?
    puts red("❌ ERROR: 1-results.csv appears empty")
    return
  end

  headers = existing_rows.first.keys

  puts "   Loaded #{existing_rows.size} existing rows"

  # ------------------------------------------------------------
  # 2. Build an index (IWAD/WAD/DEMOFILE → index in CSV)
  # ------------------------------------------------------------
  existing_index = {}
  existing_rows.each_with_index do |row, idx|
    key = [
      row['IwadFolder']&.downcase,
      row['WadFolder']&.downcase,
      row['DemoFolder']&.downcase,
      row['DemoFile']&.downcase
    ].join('|')
    existing_index[key] = idx
  end

  # ------------------------------------------------------------
  # 3. Convert failed_rows (symbol keyed hashes) → CSV-like hashes
  # ------------------------------------------------------------
  normalized_failed = failed_rows.map do |r|
    {
      "IwadFolder"   => r[:iwadfolder],
      "WadFolder"    => r[:wadfoldername],
      "DemoFolder"   => r[:demo_foldername],
      "IWAD"         => r[:iwad],
      "WAD"          => r[:wad],
      "Deh"          => r[:deh],
      "DemoFile"     => r[:demofile],
      "Expected"     => r[:expected],
      "NewActual"    => r[:new_actual],
      "NewResult"    => r[:new_result],
      "OldActual"    => r[:old_actual],
      "OldResult"    => r[:old_result],
      "Match"        => r[:match],
      "Action"       => r[:action],
      "Reason"       => r[:reason],
      "Error"        => r[:error],
      "IwadOverride" => r[:iwad_override],
      "FileOverride" => r[:file_override].is_a?(Array) ? r[:file_override].join(', ') : r[:file_override],
      "ExtraArgs"    => in_quotes(r[:extra_args]),
      "Comments"     => r[:comments],
      "Cmdline"      => r[:cmdline],
      "FolderPath"   => r[:demofolder]
    }
  end

  # ------------------------------------------------------------
  # 4. Replace matching rows
  # ------------------------------------------------------------
  updated = 0
  normalized_failed.each do |new_row|
    key = [
      new_row['IwadFolder']&.downcase,
      new_row['WadFolder']&.downcase,
      new_row['DemoFolder']&.downcase,
      new_row['DemoFile']&.downcase
    ].join('|')

    next unless existing_index.key?(key)

    idx = existing_index[key]

    puts "🔧 Updating: #{new_row['IwadFolder']}/#{new_row['WadFolder']}/#{new_row['DemoFile']}"

    merged = {}
    headers.each { |h| merged[h] = new_row[h] } # apply new row exactly

    existing_rows[idx] = merged
    updated += 1
  end

  puts "✔ Merge completed (#{updated} updated entries)"

  # ------------------------------------------------------------
  # 5. Write updated results back to results.csv
  # ------------------------------------------------------------
  CSV.open(results_path, "w", headers: headers, write_headers: true) do |csv|
    existing_rows.each do |row|
      csv << headers.map { |h| row[h] }
    end
  end

  puts "📁 Results updated in #{results_path}"
end

# ============================================================
# Demo Overrides Loader (CSV)
# ============================================================

def load_demo_overrides
  return [] unless File.exist?(OVERRIDE_IMPORT)

  # Read file and normalize line endings
  raw = File.read(OVERRIDE_IMPORT, encoding: 'bom|utf-8')
  raw.gsub!("\r\n", "\n")
  raw.gsub!("\r", "\n")

  overrides = []

  csv = CSV.parse(
    raw,
    headers: true,
    header_converters: ->(h) { h.to_s.strip.downcase }
  )

  csv.each do |row|
    fields = row.to_h

    # Pull core identifiers exactly from CSV
    iwadfolder = strip_manual_quotes(fields["iwadfolder"])
    wadfolder  = strip_manual_quotes(fields["wadfolder"])
    demofolder = strip_manual_quotes(fields["demofolder"])
    demofile   = strip_manual_quotes(fields["demofile"])

    action     = fields["action"]&.strip&.downcase

    # Skip invalid or irrelevant rows
    next if action.nil?
    next unless %w[skip override].include?(action)

    # MUST exist for matching:
    next if iwadfolder.nil? || iwadfolder.empty?
    next if wadfolder.nil?  || wadfolder.empty?
    next if demofolder.nil? || demofolder.empty?
    next if demofile.nil?   || demofile.empty?

    # Optional matching information
    reason        = fields["reason"]&.strip&.downcase
    reason = reason.gsub(/\s+/, " ") if reason

    comments       = fields["comments"]&.strip

    # OPTIONAL: IWAD Override (string or empty)
    iwad_override = strip_manual_quotes(fields["iwadoverride"])
    iwad_override = nil if iwad_override.nil? || iwad_override.empty?

    # OPTIONAL: FileOverride (comma list)
    file_override_raw = fields["fileoverride"]&.strip
    file_override =
      if file_override_raw && !file_override_raw.empty?
        file_override_raw.split(",").map { |v| strip_manual_quotes(v) }.reject(&:empty?)
      else
        []   # Always return an array
      end

    # OPTIONAL: ExtraArgs (string → always array)
    extra_raw = fields["extraargs"]&.strip
    extra_args =
      if extra_raw && !extra_raw.empty?
        # Remove wrapping quotes if present
        cleaned = extra_raw.gsub(/\A"|"\Z/, "")
        cleaned.split(/\s+/)   # split into list for CLI
      else
        []
      end

    overrides << {
      iwadfolder:    iwadfolder,
      wadfoldername: wadfolder,
      demofolder:    demofolder,
      demofile:      demofile,

      action:        action,
      reason:        reason,

      iwad_override: iwad_override,
      file_override: file_override,   # always array
      extra_args:    extra_args,      # always array
      comments:      comments
    }
  end

  overrides
end

OVERRIDES = load_demo_overrides

if OVERRIDES.any?
  puts "🧾 Loading #{OVERRIDES.size} demo override entries"
end

# ============================================================
# Utility functions
# ============================================================

def find_demo_textfile(demo_path)
  demo_dir   = File.dirname(demo_path)
  base_name  = File.basename(demo_path, File.extname(demo_path))

  # 1. Direct textfile match
  primary_txt = find_child_ci(demo_dir, "#{base_name}.txt")
  return primary_txt if primary_txt && File.exist?(primary_txt)

  # 2. Any .txt except DSDA-info.txt
  txts = files_with_ext_ci(demo_dir, '.txt')
            .reject { |t| File.basename(t).casecmp?('DSDA-info.txt') }

  # If exactly one candidate remains, use it
  return txts.first if txts.size == 1

  # 3. More than one: prefer the one that mentions wad names the most? (future?)
  # For now: no strong match → return nil
  nil
end

def find_matching_wad(demo_path, wad_files)
  return nil if wad_files.nil? || wad_files.empty?

  demo_dir = File.dirname(demo_path)
  txt_path = find_demo_textfile(demo_path)

  # Find a .txt next to the demo
  txt_content =
    if txt_path && File.exist?(txt_path)
      safe_str(File.binread(txt_path)).downcase
    else
      ""
    end

  folder_hint = safe_str(File.basename(demo_dir)).downcase
  wad_folder_hint = safe_str(File.basename(File.dirname(demo_dir))).downcase
  wad_folder_hint_without_prefix = wad_folder_hint.sub(/\A\d+[_-]?/, '')
  folder_hint_without_prefix = folder_hint.sub(/\A\d+[_-]?/, '')

  folder_hints = [
    wad_folder_hint,
    wad_folder_hint_without_prefix,
    folder_hint,
    folder_hint_without_prefix
  ].reject(&:empty?).uniq

  folder_hint_tokens = folder_hints.flat_map { |hint| hint.split(/[_\-]/) }.reject(&:empty?).uniq

  wad_info = wad_files.map do |path|
    base = File.basename(path, File.extname(path))
    { path: path, base: base, lower: base.downcase }
  end

  # Filter out likely secondary WADs (music, sound, fix, etc.)
  primary_wads = wad_info.reject { |w| w[:lower] =~ /(mus|snd|sfx|fix|sky|tex|credit|credits)/ }
  secondary_wads = wad_info - primary_wads

  # Try to match primary ones first
  match =
    (
      primary_wads.find { |w| txt_content.include?(w[:lower]) } ||
      primary_wads.find { |w| folder_hints.include?(w[:lower]) } ||
      primary_wads.find { |w| folder_hint_tokens.any? { |token| w[:lower].start_with?(token) || token.start_with?(w[:lower]) } } ||
      primary_wads.find { |w| folder_hints.any? { |hint| hint.include?(w[:lower][0, [w[:lower].size - 1, 4].max]) } } ||
      primary_wads.first ||
      secondary_wads.find { |w| txt_content.include?(w[:lower]) } ||
      secondary_wads.first
    )

  return nil unless match   # SAFETY GUARD
  match[:path]
end

def abort_all!(msg)
  $stderr.puts "\n\n#{msg}\n\n"  # Prints AFTER everything else
  Thread.list.each do |t|
    next if t == Thread.current
    begin
      t.raise(SystemExit)
    rescue
    end
  end
  exit(1)
end

# ============================================================
# Regression Setup
# ============================================================

def classify_regression(new_result:, old_result:, new_reason:, old_reason:, override_action:)
  override_skip = override_action.to_s.strip.downcase == "skip"
  override_autoskip = override_action.to_s.strip.downcase == "not run"
  new_failed = %w[fail crash timeout].include?(new_result.to_s)
  old_failed = %w[fail crash timeout].include?(old_result.to_s)

  # -------------------------------------
  # Special case: Auto skip override
  # -------------------------------------
  if override_autoskip
    return {
      match: "skip",
      ui_message: "PASS 🟢 (skip override: didn't run)",
    }
  end

  # -------------------------------------
  # Special case: Skip override
  # -------------------------------------
  if override_skip
    # NEW passes. OLD is usually not run, but forced levelstat runs it too.
    if new_result == "pass" && (old_result.nil? || old_result == "pass")
      if old_result == "pass"
        return {
          match: "skip",
          ui_message: "PASS 🟢 (skip override: both engines succeeded)",
        }
      end

      return {
        match: "skip",
        ui_message: "PASS 🟢 (skip override: old not run)",
      }
    end

    # NEW fails, OLD passes → true regression
    if new_failed && old_result == "pass"
      return {
        match: "fail - regression",
        ui_message: "FAIL 🔴 regression found",
      }
    end

    # Both fail: check reason
    if new_failed && old_failed
      if new_reason == old_reason
        return {
          match: "skip",
          ui_message: "PASS 🟢 known consistent failure (ignored)",
        }
      else
        return {
          match: "fail - regression",
          ui_message: "FAIL 🔴 regression found (different failure)",
        }
      end
    end

    # Unexpected state
    return {
      match: "fail - regression",
      ui_message: "FAIL 🔴 regression found (unexpected case?)",
    }
  end

  # -------------------------------------
  # Normal (non-skip) behavior
  # -------------------------------------

  # Timeouts are always failures
  if new_result == "timeout" || old_result == "timeout"
    return {
      match: "fail - timeout",
      ui_message: "FAIL 🔴 unexpected freeze/timeout",
    }
  end

  # Crashes are failures too
  if new_result == "crash" || old_result == "crash"
    if new_result == old_result && new_reason == old_reason
      return {
        match: "fail - match",
        ui_message: "FAIL 🔴 both crashed the same way",
      }
    end

    if new_result == "crash" && old_result == "pass"
      return {
        match: "fail - regression",
        ui_message: "FAIL 🔴 regression (NEW crashes, OLD passes)",
      }
    end

    return {
      match: "fail - regression",
      ui_message: "FAIL 🔴 regression (crash behavior changed)",
    }
  end

  # Both pass
  if new_result == "pass" && old_result == "pass"
    return {
      match: "pass - match",
      ui_message: "PASS 🟢 both engines succeeded",
    }
  end

  # NEW fails, OLD passes → regression
  if new_result == "fail" && old_result == "pass"
    return {
      match: "fail - regression",
      ui_message: "FAIL 🔴 regression (NEW fails, OLD passes)",
    }
  end

  # Both fail, compare reasons
  if new_result == "fail" && old_result == "fail"
    if new_reason == old_reason
      return {
        match: "fail - match",          # same failure mode
        ui_message: "FAIL 🔴 both failed the same way (research required)",
      }
    else
      return {
        match: "fail - regression",
        ui_message: "FAIL 🔴 regression (different failure mode)",
      }
    end
  end

  {
    match: "fail - unknown",
    ui_message: "FAIL 🔴 unable to get result (NEW=#{new_result.inspect}, OLD=#{old_result.inspect})",
  }
end

def levelstats_match?(new_path, old_path)
  return nil unless new_path && old_path
  return nil unless File.exist?(new_path) && File.exist?(old_path)

  Utility::Levelstat.new(new_path).rows == Utility::Levelstat.new(old_path).rows
end

# ============================================================
# Core: Run demo
# ============================================================

def add_flag(cmd, displaycmd, flag)
  cmd        << flag
  displaycmd << flag
end

def add_path(cmd, displaycmd, path)
  cmd        << path     # raw, no quotes!
  displaycmd << q(path)  # quoted for display
end

def execute_demo_process(cmd:, worker_dir:, exe:, log:)
  output = String.new(encoding: Encoding::BINARY)
  timed_out = false
  status = nil
  fail_reason = nil
  tmp_path = nil
  pid = nil

  begin
    # SAFETY CHECK - prevent accidental overwrite of EXE output.
    if worker_dir.start_with?(PORTS_PATH)
      raise "CRITICAL ERROR: worker_dir resolved to build folder: #{worker_dir}"
    end

    # Create temp output file inside worker_dir.
    tmp_path = File.join(worker_dir, "demotest_#{exe}_output_#{Process.pid}_#{rand(100_000_000)}.log")
    FileUtils.touch(tmp_path)

    # Spawn the engine with worker_dir as cwd.
    pid = Process.spawn(*cmd, chdir: worker_dir, out: tmp_path, err: tmp_path)

    begin
      Timeout.timeout(TIMEOUT_SECS) do
        Process.wait(pid)
        status = $?
      end
    rescue Timeout::Error
      timed_out = true
      fail_reason = "timeout after #{TIMEOUT_SECS}s"
      thread_log(log) { puts red("⏱️  Demo timed out after #{TIMEOUT_SECS}s") }

      begin
        Process.kill('TERM', pid) rescue nil
        sleep 0.5
        Process.kill('KILL', pid) rescue nil
      rescue Errno::ESRCH
      end
    end
  rescue => e
    thread_log(log) { puts "[Error executing demo-test: #{e.message}]" }
    fail_reason = e.message
  ensure
    # Read the last 2KB of engine output, then remove the temp log.
    if tmp_path && File.exist?(tmp_path)
      begin
        File.open(tmp_path, "rb") do |f|
          f.seek(-2048, IO::SEEK_END) rescue nil
          output = f.read || ""
        end
      ensure
        FileUtils.rm_f(tmp_path) rescue nil
      end
    end
  end

  [status, timed_out, fail_reason, output]
end

def run_demo_with_exe(
  exe:,
  iwad:,
  file_list:,
  demo_path:,
  extra_args: [],
  override: nil,
  log: nil,
  worker_dir: nil
)
  exe_path = case exe.to_s
             when "new" then EXE_PATH
             when "old" then OLD_EXE_PATH
             else
               raise "Invalid exe: #{exe.inspect} (must be \"new\" or \"old\")"
             end

  cmd = [exe_path]
  displaycmd = [q(exe_path)]

  demo_dir = File.dirname(demo_path)

  # ==========================================================
  # IWAD handling
  # ==========================================================
  if iwad && !iwad.empty?
    add_flag(cmd, displaycmd, '-iwad')
    iwad_path = find_child_ci(IWAD_WAD_PATH, iwad) || File.join(IWAD_WAD_PATH, iwad)
    add_path(cmd, displaycmd, iwad_path)
  end

  # ==========================================================
  # PWAD / DEH handling (all passed under -file)
  # ==========================================================

  file_args = file_list || []

  if file_args.any?
    add_flag(cmd, displaycmd, '-file')
    file_args.each do |path|
      add_path(cmd, displaycmd, path)
    end
  end

  # Precompute relative paths (used in both overrides + listing)
  rel_files = normalize_demo_relative_paths(file_args, demo_path)

  # ==========================================================
  # LOGGING: Header line ("🎬 Running …")
  # ==========================================================
  thread_log(log) do
    command_text    = exe.to_s == "new" ? "Running" : "Regression test"
    demo_name       = File.basename(demo_path)
    wadfolder_name  = File.basename(File.dirname(demo_path))
    iwadfolder_name = iwad ? File.basename(iwad, File.extname(iwad)) : "(unknown)"
    puts "🎬 #{command_text}: #{iwadfolder_name}/#{wadfolder_name}/#{demo_name} ..."
  end

  # ==========================================================
  # LOGGING: IWAD override, file override, file list, extras
  # ==========================================================

  # Show IWAD override if present
  if override && override[:iwad_override]
    thread_log(log) { puts "🎛️ IWAD Override: #{override[:iwad_override]}" }
  end

  # Show File Override if present
  if override && override[:file_override] && override[:file_override].any?
    pretty = override[:file_override].map(&:to_s).join(", ")
    thread_log(log) { puts "📦 File Override: #{pretty}" }
  else
    # Otherwise show normal resolved file list
    if file_args.any?
      thread_log(log) { puts "📦 File list: #{rel_files.join(', ')}" }
    else
      thread_log(log) { puts "📦 File list: (IWAD only)" }
    end
  end

  # Show extra engine arguments if present
  if extra_args && extra_args.any?
    thread_log(log) { puts "📜 Extra args: #{extra_args.join(' ')}" }
  end

  # Add main demo parameters
  add_flag(cmd, displaycmd, '-fastdemo')
  add_path(cmd, displaycmd, demo_path)
  add_flag(cmd, displaycmd, '-nosound')
  add_flag(cmd, displaycmd, '-nomusic')
  add_flag(cmd, displaycmd, '-nodraw')
  add_flag(cmd, displaycmd, '-levelstat')
  add_flag(cmd, displaycmd, '-analysis')
  add_flag(cmd, displaycmd, '-noautoload')

  # Add extra CLI arguments if provided
  if extra_args.any?
    cmd += extra_args
    displaycmd += extra_args
  end

  # ==========================================================
  # Prepare worker output files
  # ==========================================================
  worker_dir ||= demo_dir
  FileUtils.mkdir_p(worker_dir)

  # --- INSERT THIS ---
  if worker_dir.start_with?(PORTS_PATH)
    raise "CRITICAL: worker_dir='#{worker_dir}' is inside PORTS_PATH! Aborting to avoid overwriting executables."
  end
  # -------------------

  analysis_path  = File.join(worker_dir, "analysis.txt")
  levelstat_path = File.join(worker_dir, "levelstat.txt")

  # Ensure fresh start
  FileUtils.rm_f(analysis_path)
  FileUtils.rm_f(levelstat_path)

  thread_log(log) { puts "\n🧠 Running command:\n   #{displaycmd.join(' ')}" }
  play_cmd = sanitize_cmdline(displaycmd.join(" "))

  result = nil
  actual_time = nil
  error_hint = nil

  status, timed_out, fail_reason, output = execute_demo_process(
    cmd: cmd,
    worker_dir: worker_dir,
    exe: exe,
    log: log
  )

  if !timed_out && status&.exitstatus == 0 && !wait_for_file(levelstat_path)
    thread_log(log) do
      retry_reason = if LEVELSTAT_COMPARE
                       "before comparing levelstat output"
                     else
                       "to confirm the demo result"
                     end
      puts yellow("⚠️  levelstat.txt missing after clean exit. Retrying once #{retry_reason}")
    end

    FileUtils.rm_f(analysis_path)
    FileUtils.rm_f(levelstat_path)

    status, timed_out, fail_reason, output = execute_demo_process(
      cmd: cmd,
      worker_dir: worker_dir,
      exe: exe,
      log: log
    )

    wait_for_file(levelstat_path) if !timed_out && status&.exitstatus == 0
  end

  # --------------------------------------------------
  # Early spawn failure: treat as crash
  # --------------------------------------------------
  spawn_failed = fail_reason && status.nil? && !timed_out

  if spawn_failed
    result = "crash"
    # output is probably empty, but that's fine
    return [
      result,
      output,
      actual_time,
      fail_reason,
      error_hint,
      play_cmd,
      analysis_path,
      levelstat_path
    ]
  end

  # --- Encoding cleanup ---
  begin
    output = output.force_encoding(Encoding::BINARY)
    output = output.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
    output.gsub!(/[\x00-\x08\x0B\x0C\x0E-\x1F]/, '')
  rescue => e
    puts "[Encoding cleanup failed in demo-test: #{e.class} - #{e.message}]"
    output = output.encode('UTF-8', invalid: :replace, undef: :replace, replace: '') rescue output.scrub
  end

  # --------------------------------------------------
  # STEP 1 — Timeout?
  # --------------------------------------------------
  if timed_out
    result = 'timeout'
    fail_reason = "timeout after #{TIMEOUT_SECS}s"
  else
    # --------------------------------------------------
    # STEP 2 — Grab a helpful error hint (last error-style line)
    # --------------------------------------------------
    patterns = [
      /(G_[A-Za-z0-9_]+:\s+.+)/,
      /(W_[A-Za-z0-9_]+:\s+.+)/,
      /(P_[A-Za-z0-9_]+:\s+.+)/,
      /([A-Z][A-Za-z0-9_]+ error:\s+.+)/
    ]

    candidates = []

    patterns.each do |regex|
      output.scan(regex) do |match|
        candidates << match.first.strip
      end
    end

    error_hint = candidates.last if candidates.any?

    # --------------------------------------------------
    # STEP 3 — Crash?
    # For this function, “crash” = non-zero exitstatus.
    # Unsupported formats will be handled OUTSIDE by detect_demo_engine_from_log.
    # --------------------------------------------------
    engine = detect_demo_engine_from_log(output)
    exit_error = (status && status.exitstatus && status.exitstatus != 0)
    crash_detected = exit_error && engine.nil?
    crash_message = crash_message?(status)
  
    show_crash_log = crash_detected && !(override && override[:action] == "skip")

    if show_crash_log && crash_message
      thread_log(log) { puts crash_message }
    end

    # Hard crash before writing stats
    if crash_detected && !File.exist?(levelstat_path)
      result      = "crash"
      fail_reason ||= crash_message || "engine crashed"
    else
      # --------------------------------------------------
      # STEP 4 — levelstat missing without nonzero exit → treat as run failure
      # --------------------------------------------------
      unless File.exist?(levelstat_path)
        result      = "fail"
        fail_reason ||= "missing levelstat (demo did not finish)"
      else

        # --------------------------------------------------
        # STEP 5 — Parse analysis + levelstat
        # --------------------------------------------------
        begin
          analysis   = Utility::Analysis.new(analysis_path)
          levelstat  = Utility::Levelstat.new(levelstat_path)

          actual_time = levelstat.total

          run_success = (analysis.category && levelstat.total != '00:00')

          # Demo finished and did not soft-fail
          if run_success
            result = "pass"
          else
            result = "fail"
            fail_reason ||= "run failed"
          end

        rescue => e
          result      = "fail"
          fail_reason = "result-parsing-error: #{e.class} - #{e.message}"
        end
      end
    end
  end

# ==========================================================
# STEP 6 — Rename/copy engine output files for isolation
# ==========================================================
suffix = exe.to_s        # "new" or "old"

# Original engine outputs
orig_analysis   = analysis_path      # worker_dir/analysis.txt
orig_levelstat  = levelstat_path     # worker_dir/levelstat.txt

# Final stored files (no overwriting between new/old)
final_analysis   = File.join(worker_dir, "analysis_#{suffix}.txt")
final_levelstat  = File.join(worker_dir, "levelstat_#{suffix}.txt")

# Remove stale copies
FileUtils.rm_f(final_analysis)
FileUtils.rm_f(final_levelstat)

# Copy fresh outputs
FileUtils.cp(orig_analysis,  final_analysis)  if File.exist?(orig_analysis)
FileUtils.cp(orig_levelstat, final_levelstat) if File.exist?(orig_levelstat)

# Remove originals to avoid cross-run contamination
FileUtils.rm_f(orig_analysis)
FileUtils.rm_f(orig_levelstat)

# =====================================================
#  DONE determining:
#     result, actual_time, fail_reason, error_hint
#
#  DO NOT copy files here.
#  Just return the paths so the caller can decide what to do.
# =====================================================

  return [
    result,
    output,
    actual_time,
    fail_reason,
    error_hint,
    play_cmd,
    final_analysis,
    final_levelstat
  ]
end

# ============================================================
# Main
# ============================================================

PRIMARY_IWADS = %w[doom2 doom plutonia tnt].freeze
EXOTIC_IWADS  = %w[heretic hexen chex].freeze

def select_demo_folders(raw_query)
  demo_folders = []

  # -----------------------------------------
  # CASE 0: No argument → run primary IWADs; --all includes exotic IWADs too
  # -----------------------------------------
  if raw_query.nil?
    selected_iwads = RUN_ALL_IWADS ? (PRIMARY_IWADS + EXOTIC_IWADS) : PRIMARY_IWADS

    selected_iwads.each do |iwad|
      iwad_path = resolve_path_ci(DEMOS_ROOT, iwad)
      next unless iwad_path && Dir.exist?(iwad_path)

      Dir.children(iwad_path).each do |wadname|
        demo_folders.concat collect_demo_folders(File.basename(iwad_path), wadname)
      end
    end

    scope = RUN_ALL_IWADS ? "all IWADs" : "primary IWADs"
    puts "🎯 No argument → running #{scope} (#{demo_folders.size})"
    return demo_folders
  end

  # -----------------------------------------
  # CASE 1: Query starts with explicit IWAD
  # -----------------------------------------
  parts = raw_query.split('/').map(&:strip)
  explicit_iwad = parts.first.downcase

  if (PRIMARY_IWADS + EXOTIC_IWADS).include?(explicit_iwad)
    wadname  = parts[1]
    selector = parts[2]

    # --- NEW: if only IWAD is provided → run all wads under that IWAD ---
    unless wadname
      iwad_path = resolve_path_ci(DEMOS_ROOT, explicit_iwad)
      abort("❌ No such IWAD directory: #{explicit_iwad}/") unless iwad_path && Dir.exist?(iwad_path)

      Dir.children(iwad_path).each do |wadfolder|
        demo_folders.concat collect_demo_folders(File.basename(iwad_path), wadfolder)
      end

      puts "🎯 Running all demos for IWAD #{explicit_iwad} (#{demo_folders.size} sets)"
      return demo_folders
    end

    abort("❌ No such wad directory: #{explicit_iwad}/#{wadname}") unless wad_exists?(explicit_iwad, wadname)

    if selector
      full = resolve_path_ci(DEMOS_ROOT, File.join(explicit_iwad, wadname, selector))
      abort("❌ No match for #{explicit_iwad}/#{wadname}/#{selector}") unless full && File.exist?(full)
      demo_folders << full
      puts "🎯 Selected demo: #{full}"
    else
      demo_folders.concat collect_demo_folders(explicit_iwad, wadname)
      puts "🎯 Running all demos for #{explicit_iwad}/#{wadname}"
    end

    return demo_folders
  end

  # -----------------------------------------
  # CASE 2: Query is WAD-only (auto-detect IWAD)
  # -----------------------------------------
  wadname  = parts[0]
  selector = parts[1]

  found_iwad =
    PRIMARY_IWADS.find { |iwad| wad_exists?(iwad, wadname) }

  abort("❌ Wad '#{wadname}' not found in doom2/ doom/ plutonia/ tnt/") unless found_iwad

  if selector
    full = resolve_path_ci(DEMOS_ROOT, File.join(found_iwad, wadname, selector))
    abort("❌ Selector '#{selector}' not found under #{found_iwad}/#{wadname}") unless full && File.exist?(full)
    demo_folders << full
  else
    demo_folders.concat collect_demo_folders(found_iwad, wadname)
  end

  demo_folders
end

def wad_root_path(iwad)
  resolve_path_ci(DEMOS_ROOT, iwad) || File.join(DEMOS_ROOT, iwad)
end

def wad_dir_path(iwad, wadname)
  iwad_path = resolve_path_ci(DEMOS_ROOT, iwad)
  return nil unless iwad_path

  resolve_path_ci(iwad_path, wadname)
end

def wad_exists?(iwad, wadname)
  path = wad_dir_path(iwad, wadname)
  path && Dir.exist?(path)
end

def collect_demo_folders(iwad, wadname)
  base = wad_dir_path(iwad, wadname)
  return [] unless base && Dir.exist?(base)

  Dir.children(base).map { |child|
    File.join(base, child)
  }.select { |path|
    # Valid demo folders:
    (
      File.directory?(path) &&
      File.basename(path).downcase !~ /-wad$/ &&
      files_with_ext_ci(path, '.lmp').any?
    ) ||
    File.basename(path).casecmp?("manual")
  }
end

FAILED_DEMOS = load_failures_list
FAILED_ONLY_UNRESOLVED = []

if FAILED_ONLY
  puts "🔁 Running ONLY failed demos from 2-failures.csv..."
  total = FAILED_DEMOS.values.map(&:size).sum

  # check if there are any failed demos, exit if not
  if total == 0
    puts "❌ No failed demos found"
    puts "💤 Exiting early — nothing to process."
    exit 0
  end

  puts "📦 Loaded #{total} failed demos"
end

raw_query = ARGV[0]&.strip

# ============================================================
# do NOT discover folders in failed-only mode
# ============================================================
if FAILED_ONLY
  demo_folders = []    # skip auto-discovery completely
else
  demo_folders = select_demo_folders(raw_query)
end

# ============================================================
# Build demo_folders directly from failures.csv
# ============================================================
if FAILED_ONLY
  demo_folders = []

  FAILED_DEMOS.each do |(iwad, wad), demofile_set|
    demofile_set.each do |demofile|
      folder_path = wad_dir_path(iwad, wad)

      # Find the demo folder that actually contains this .lmp
      matching = if folder_path && Dir.exist?(folder_path)
        Dir.children(folder_path)
           .map { |child| File.join(folder_path, child) }
           .select { |d| File.directory?(d) }
           .find do |d|
             files_with_ext_ci(d, '.lmp').any? { |lmp| File.basename(lmp).casecmp?(demofile) }
           end
      end

      if matching
        demo_folders << matching
      else
        puts red("❌ Failed-only: could not locate demo folder for #{iwad}/#{wad}/#{demofile}")
        FAILED_ONLY_UNRESOLVED << "#{iwad}/#{wad}/#{demofile}"
      end
    end
  end

  demo_folders.uniq!
  puts "🔍 Found #{demo_folders.size} demo folders containing failed demos"
end

if COMPLEVEL_FILTER
  before_filter = demo_folders.size
  matched_folders = []
  last_index_status = Time.now

  puts "🔎 Indexing complevel metadata for #{before_filter} demo folders..."

  demo_folders.each_with_index do |folder, index|
    matched_folders << folder if dsda_info_complevel(folder) == COMPLEVEL_FILTER

    scanned = index + 1
    now = Time.now
    next unless scanned == before_filter || now - last_index_status >= 2

    percent = before_filter.zero? ? 100.0 : (scanned.to_f / before_filter * 100)
    puts "   📚 Indexed #{scanned} / #{before_filter} folders (#{format('%.1f', percent)}%) — #{matched_folders.size} matched cl#{COMPLEVEL_FILTER}"
    last_index_status = now
  end

  demo_folders = matched_folders
  excluded = before_filter - demo_folders.size
  puts "🎯 Complevel filter cl#{COMPLEVEL_FILTER}: selected #{demo_folders.size} demo folders (excluded #{excluded})"
end

# ============================================================
# Group demo folders by WAD (parallelization unit)
# ============================================================

wad_groups = demo_folders.group_by do |folder|
  iwad = File.basename(File.dirname(File.dirname(folder)))
  wad  = File.basename(File.dirname(folder))
  [iwad, wad]
end

SINGLE_FOLDER_MODE = (wad_groups.size == 1)

puts "🔍 Found #{wad_groups.size} WAD groups for parallel execution"

# ============================================================
# setup parallel jobs
# ============================================================

results_mutex = Mutex.new
results = []

# Detect number of cores automatically
TOTAL_CORES = Parallel.processor_count

# Use 75% of cores by default to avoid system slowdown
MAX_CORES = [(TOTAL_CORES * CPU_CORE_PERCENT).floor, 1].max

puts "⚙️ Parallel mode: detected #{TOTAL_CORES} cores, using #{MAX_CORES} threads"

# Progress tracking setup
$total_sets = demo_folders.size
$completed_sets = 0
$total_wads = wad_groups.size
$completed_wads = 0

$last_progress_time = Time.now
$progress_mutex = Mutex.new
global_start_time = Time.now

puts "📊 Tracking progress per demo folder (#{$total_sets} total sets across #{$total_wads} WADs)"

# ============================================================
# Begin actual demo test
# ============================================================

puts ("🚗 Starting bulk demo regression test")
puts ("----------------------------------------------------------------------\n")

# ============================================================
# 🫀 Background heartbeat thread (keeps console alive)
# ============================================================
Thread.new do
  loop do
    sleep HEARTBEAT_SECS
    $progress_mutex.synchronize do

      # stop once everything is done
      break if $completed_sets >= $total_sets

      percent = ($completed_sets.to_f / [$total_sets, 1].max * 100)
      percent_str = percent.to_i == percent ? percent.to_i.to_s : percent.round(1).to_s
      elapsed = format_duration(Time.now - global_start_time)
      current_time = Time.now.strftime("%I:%M %p")
      sets_left   = $total_sets - $completed_sets
      wads_left   = $total_wads - $completed_wads

      $print_mutex.synchronize do
        # puts orange("💤 Still working... #{$completed_sets} / #{$total_sets} demo folders (#{percent_str}%) [#{current_time}] - #{elapsed} elapsed")
        puts orange("💤 Still working... #{sets_left} demo folders, #{wads_left} WADs left (#{percent_str}%) [#{current_time}] - #{elapsed} elapsed")
      end
    end
  end
end

# ============================================================
# Demo Info Stuff
# ============================================================

def setup_demo_info(demo_folder_path, lmp_path)
  # Identify IWAD + <wad_name> folder name
  wad_name   = File.basename(File.dirname(demo_folder_path))
  iwad_name  = File.basename(File.dirname(File.dirname(demo_folder_path)))
  iwad_file  = "#{iwad_name}.wad"

  # Locate <wad_name>-wad directory
  wad_root_path    = File.dirname(demo_folder_path)
  wad_folder_path  = find_child_ci(wad_root_path, "#{wad_name}-wad") ||
                     File.join(wad_root_path, "#{wad_name}-wad")

  # Collect WADs but EXCLUDE wadfolder/extra/*
  wad_folder_wads = files_with_ext_ci(wad_folder_path, '.wad', recursive: true)
    .reject { |p| p.match?(/(^|[\/\\])extra([\/\\])/i) }

  # Collect DEH/BEX but EXCLUDE wadfolder/extra/*
  wad_folder_dehs = files_with_ext_ci(wad_folder_path, '.deh', '.bex', recursive: true)
    .reject { |p| p.match?(/(^|[\/\\])extra([\/\\])/i) }

  # Scan demo folder for assets
  demo_folder_wads = files_with_ext_ci(demo_folder_path, '.wad')
  demo_folder_dehs = files_with_ext_ci(demo_folder_path, '.deh', '.bex')

  # Primary PWAD matching
  primary_wad = find_matching_wad(lmp_path, wad_folder_wads)
  default_dehs = wad_folder_dehs + demo_folder_dehs

  # Lookup overrides
  demo_name = File.basename(lmp_path)
  demo_foldername = File.basename(demo_folder_path)

  override = OVERRIDES.find do |ov|
    ov[:iwadfolder]&.casecmp?(iwad_name) &&
    ov[:wadfoldername]&.casecmp?(wad_name) &&
    ov[:demofolder].casecmp?(demo_foldername) &&
    ov[:demofile]&.casecmp?(demo_name)
  end

  # Final environment hash
  {
    # demo identification
    demo_folder_path:   demo_folder_path,
    lmp_path:           lmp_path,
    demo_name:          demo_name,
    demo_foldername:    demo_foldername,

    # wad hierarchy
    wad_name:           wad_name,
    iwad_name:          iwad_name,
    iwad_file:          iwad_file,

    # wad folder contents
    wad_folder_path:    wad_folder_path,
    wad_folder_wads:    wad_folder_wads,
    wad_folder_dehs:    wad_folder_dehs,

    # demo folder contents
    demo_folder_wads:   demo_folder_wads,
    demo_folder_dehs:   demo_folder_dehs,

    # primary pwad & default dehs
    primary_wad:        primary_wad,
    default_dehs:       default_dehs,

    # overrides
    override:           override
  }
end

# Mapping of prefix → base folder
WAD_OVERRIDE_PATHS = {
  "demo_dir/" => ->(rel, demo_folder) { File.join(demo_folder, rel) },
  "EX/"       => ->(rel, _demo)       { File.join(EXTRA_WAD_PATH, rel) },
  "CM/"       => ->(rel, _demo)       { File.join(COMMERCIAL_WAD_PATH, rel) },
  "ML/"       => ->(rel, _demo)       { File.join(MASTER_LEVELS_PATH, rel) }
}.freeze

# commercial wads are optional
COMMERCIAL_PREFIXES = ["CM/", "ML/"].freeze

def auto_file_override_entries(env)
  return [] unless defined?(AUTO_FILE_OVERRIDES)

  key = "#{env[:iwad_name]}/#{env[:wad_name]}".downcase
  spec = AUTO_FILE_OVERRIDES[key]
  return [] unless spec

  entries =
    if spec.is_a?(Hash)
      demo_folder = env[:demo_foldername].to_s.downcase
      demo_folder_specs = spec[:demo_folders] || spec["demo_folders"] || {}
      demo_overrides = demo_folder_specs.transform_keys { |k| k.to_s.downcase }
      demo_overrides[demo_folder] || spec[:default] || spec["default"]
    else
      spec
    end

  Array(entries).map(&:to_s).reject(&:empty?)
end

def auto_unsupported_info(env)
  return nil unless defined?(AUTO_FILE_UNSUPPORTED)

  key = "#{env[:iwad_name]}/#{env[:wad_name]}".downcase
  info = AUTO_FILE_UNSUPPORTED[key]
  return nil unless info

  if info.is_a?(Hash)
    comments = info[:comments] || info["comments"] || info[:comment] || info["comment"]
    reason = info[:reason] || info["reason"] || "unsupported"
  else
    comments = Array(info).join(", ")
    reason = "unsupported"
  end

  { reason: reason.to_s, comments: comments.to_s }
end

def resolve_override_path(entry, demo_folder_path, wad_folder_path)
  # 1. Handle all special prefixes (demo_dir/, ML/, CM/)
  WAD_OVERRIDE_PATHS.each do |prefix, resolver|
    next unless entry.downcase.start_with?(prefix.downcase)

    rel  = entry[prefix.length..]
    path = resolver.call(rel, demo_folder_path)
    resolved = case prefix
               when "demo_dir/"
                 resolve_path_ci(demo_folder_path, rel)
               when "EX/"
                 resolve_path_ci(EXTRA_WAD_PATH, rel)
               when "CM/"
                 resolve_path_ci(COMMERCIAL_WAD_PATH, rel)
               when "ML/"
                 resolve_path_ci(MASTER_LEVELS_PATH, rel)
               end

    # --- Commercial? Then missing file should not raise ---
    if COMMERCIAL_PREFIXES.include?(prefix)
      return resolved if resolved && File.exist?(resolved)
      return [:commercial_missing, entry, path]
    end

    # --- Normal behavior (demo_dir/, EX/, etc) ---
    return resolved if resolved && File.exist?(resolved)

    raise "Override file not found: #{entry} (expected at #{path})"
  end

  # 2. Normal override → resolve ONLY inside wadfolder
  path = File.join(wad_folder_path, entry)
  resolved = resolve_path_ci(wad_folder_path, entry)
  return resolved if resolved && File.exist?(resolved)

  raise "Override file not found: #{entry} (expected at #{path})"
end

def prepare_demo_info(env)
  iwad_file         = env[:iwad_file]
  primary_wad       = env[:primary_wad]
  demo_folder_path  = env[:demo_folder_path]
  wad_folder_path   = env[:wad_folder_path]
  override          = env[:override]

  default_wads = []

  # 1. Primary wad (picked from wadfolder-wad)
  if env[:primary_wad]
    default_wads << env[:primary_wad]
  end

  # 2. Demo folder wads must *always* supplement the primary wad 
  default_wads.concat(env[:demo_folder_wads])

  default_wads.uniq!

  final_wads = default_wads.dup
  final_dehs = env[:default_dehs].dup

  extra_args = []
  override_iwad_flag = false
  final_override_files = nil
  auto_unsupported = auto_unsupported_info(env)
  explicit_file_override = override &&
                           override[:action] == "override" &&
                           override[:file_override] &&
                           !override[:file_override].empty?
  iwad_only_override = explicit_file_override &&
                       override[:file_override].any? { |v| v.to_s.strip.upcase == "IWAD_ONLY" }

  unless explicit_file_override || iwad_only_override
    auto_override_list = auto_file_override_entries(env)
    if auto_override_list.any?
      final_wads = auto_override_list.map do |entry|
        resolve_override_path(entry, demo_folder_path, wad_folder_path)
      end
      final_wads.concat(env[:demo_folder_wads])
      final_wads.uniq!
    end
  end

  # Apply overrides
  if override && override[:action] == "override"
    # IWAD override
    if override[:iwad_override] && !override[:iwad_override].empty?
      iwad_file = override[:iwad_override]
      override_iwad_flag = true
    end

    if iwad_only_override
      final_wads = []
      final_dehs = []
      final_override_files = []
    end

    # File overrides
    if explicit_file_override && !iwad_only_override
      override_list = override[:file_override]

      # User supplied the full list → we trust it exactly
      final_override_files = override_list.map do |entry|
        resolve_override_path(entry, demo_folder_path, wad_folder_path)
      end

      # When override list is used, we DO NOT use default WAD/DEH logic.
      final_wads = []
      final_dehs = []
    end

    # Extra args
    if override[:extra_args] && !override[:extra_args].empty?
      extra_args = override[:extra_args]
    end
  end

  # DEH sorting (only if NOT final_override_files)
  if final_override_files.nil? && final_dehs.any?
    final_dehs.sort_by! do |path|
      rel = path.sub(/^#{Regexp.escape(demo_folder_path)}[\/\\]?/, '')
      is_subfolder = rel.include?('/') || rel.include?('\\')
      [is_subfolder ? 0 : 1, rel.downcase]
    end
  end

  # Output final execution-ready config
  {
    iwad_file:          iwad_file,
    wads:               final_wads,
    dehs:               final_dehs,
    override_files:     final_override_files,  # array or nil
    extra_args:         extra_args,
    override_iwad_flag: override_iwad_flag,
    skip:               (override && override[:action] == "skip") || !!auto_unsupported,
    reason:             (override && override[:reason]) || auto_unsupported&.dig(:reason),
    auto_comments:      auto_unsupported&.dig(:comments)
  }
end

# ============================================================
# Run all demo folders in parallel
# ============================================================

SKIP_IMMEDIATE = [
  "crash",
  "freeze",
  "unpredicatable",
  "duplicate",
  "ignore",
  "unsupported",
  "wrong iwad",
  "wrong wad",
  "bad wad",
  "too long"
].map { |s| s.downcase }

Parallel.each(wad_groups.keys, in_threads: MAX_CORES) do |(iwad, wadname)|
  demo_folder_list = wad_groups[[iwad, wadname]]

  # One log buffer per WAD
  log = []
  wad_start_time = Time.now
  local_results = []
  folder_failed = false

  begin
    # WAD-level header
    log_line(log, "----------------------------------------------------------------------")
    log_line(log, "🧵 [Thread #{Thread.current.object_id.to_s(16)}] Processing WAD #{iwad}/#{wadname} - (#{demo_folder_list.size} demo folders)")
    log_line(log, "")

    # ==========================================================
    # Process ALL demo folders sequentially in THIS thread
    # ==========================================================

    demo_folder_list.each do |demo_folder_path|
      # NEW: Scan demo folder for lmps
      demo_lmps = files_with_ext_ci(demo_folder_path, '.lmp')

      # Completely silence "manual" folders unless they actually contain demos
      if File.basename(demo_folder_path).casecmp?("manual")
        # Count as a valid completed folder, but produce no output
        $completed_sets += 1
        next
      end

      log_line(log, "")
      log_line(log, "----------------------------------------------------------------------")
      log_line(log, "📁 Processing demo folder \"#{demo_folder_path}\"")
      log_line(log, "")

      # Other empty folders: silently skip too
      if demo_lmps.empty?
        # Count as complete, but produce no noisy output
        $completed_sets += 1
        next
      end

      # --- STRICT FILTER FOR --failed-only MODE ---
      if FAILED_ONLY
        iwad = File.basename(File.dirname(File.dirname(demo_folder_path))).downcase
        wad  = File.basename(File.dirname(demo_folder_path)).downcase
        key  = [iwad, wad]

        if FAILED_DEMOS.key?(key)
          allowed = FAILED_DEMOS[key]
          demo_lmps = demo_lmps.select do |lmp|
            allowed.include?(File.basename(lmp).downcase)
          end
        else
          demo_lmps = []   # no failed demos in this folder
        end
      end
      # ------------------------------------------------

      # Process EACH .lmp in the folder
      demo_lmps.each do |lmp_path|
        demo_name = File.basename(lmp_path)
        env = nil
        base_info = nil
        override_info = nil

        begin
          # Step 1: Gather raw info
          env = setup_demo_info(demo_folder_path, lmp_path)

          # ==========================================================
          # NEW deterministic worker directory:
          # tmp/tmp_demos/<iwad>/<wad>/<demo_folder>/<demo_name>/
          # ==========================================================

          worker_dir = File.join(
            DEMOS_CACHE_ROOT,
            env[:iwad_name],
            env[:wad_name],
            File.basename(env[:demo_folder_path]),
            File.basename(env[:lmp_path])
          )

          FileUtils.mkdir_p(worker_dir)

          # Cleanup any stale files inside this folder
          Dir.foreach(worker_dir) do |f|
            next if f == "." || f == ".."
            FileUtils.rm_f(File.join(worker_dir, f))
          end

          primary_wad     = env[:primary_wad]
          wadfolder_name  = env[:wad_name]
          iwadfolder_name = env[:iwad_name]
          default_dehs    = env[:default_dehs]
          override        = env[:override]

          # Step 2: Resolve all WAD/DEH/override behavior
          resolved = prepare_demo_info(env)
          iwad_file       = resolved[:iwad_file]
          final_wads      = resolved[:wads]
          final_dehs      = resolved[:dehs]
          override_list   = resolved[:override_files]
          extra_args      = resolved[:extra_args]
          override_iwad   = resolved[:override_iwad_flag]
          should_skip     = resolved[:skip]
          skip_reason     = resolved[:reason]
          auto_comments   = resolved[:auto_comments]

          # Placeholder for old/new engine results
          old_result  = ""
          expected = ""
          old_actual   = ""
          old_reason   = ""
          match = ""

          # Build the actual linear file list
          if override_list && !override_list.empty?
            final_files = override_list
          elsif final_wads.any? || final_dehs.any?
            final_files = final_wads + final_dehs
          else
            final_files = []
          end

          # -------------------------
          # -1. Get basic info before crash/freeze entries
          # -------------------------
          nice_default_dehs = normalize_demo_relative_paths(default_dehs, lmp_path)
          base_info = {
            iwadfolder:     iwadfolder_name,
            wadfoldername:  wadfolder_name,
            demo_foldername: File.basename(env[:demo_folder_path]),

            iwad:       iwad_file,
            wadfolder:  wadfolder_name,
            wad:        primary_wad ? File.basename(primary_wad) : nil,
            deh:        nice_default_dehs.join(", "),
            demofile:   safe_str(demo_name)
          }

          override_info = {
            iwad_override: override ? override[:iwad_override] : nil,
            file_override: override ? override[:file_override] : nil,
            extra_args:    override ? override[:extra_args]    : nil,
            comments:      (override ? override[:comments] : nil) || auto_comments,
            demofolder:    override ? override[:demofolder]    : nil
          }

          # --------------------------------------------------------
          # X. Auto-skip if any override refers to missing CM/ or ML/
          # --------------------------------------------------------
          if override_list && override_list.any? { |f| f.is_a?(Array) && f[0] == :commercial_missing }
            missing_item   = override_list.find { |f| f.is_a?(Array) && f[0] == :commercial_missing }
            entry          = missing_item[1]  # "CM/nerve.wad"
            expected_path  = missing_item[2]
            short_name     = File.basename(entry.sub(/^[A-Z]+\//,''))  # nerve.wad

            reason_for_display = "#{short_name} (commercial) not found"

            log_line(log, yellow("⚠️ Skipping demo #{iwadfolder_name}/#{wadfolder_name}/#{demo_name} (#{reason_for_display})"))

            local_results << build_result_row(
              base: base_info,
              override: override_info,
              runtime: {
                expected: nil,

                new_actual: nil,
                new_result: nil,

                old_actual: nil,
                old_result: nil,

                match: "skip",
                action: "not run",
                reason: reason_for_display,
                error: nil,

                cmdline: nil,
                folderpath: nil
              }
            )

            log_line(log, "\n")
            next
          end

          # --------------------------------------------------------
          # 0. Skip demos marked as crash/freeze/duplicate
          # or are just way too fucking long (9 hours wtf)
          # --------------------------------------------------------
          if should_skip && SKIP_IMMEDIATE.include?(skip_reason.to_s.strip.downcase)

            # Old behavior: prefer override reason, fallback to "crash"
            reason_for_display = skip_reason || "crash"

            log_line(log, yellow("⚠️ Skipping demo #{iwadfolder_name}/#{wadfolder_name}/#{demo_name} (#{reason_for_display})"))

            # Record result as a skip with a special reason
            local_results << build_result_row(
              base: base_info,
              override: override_info,
              runtime: {
                expected:     nil,

                new_actual:   nil,
                new_result:   nil,

                old_actual:   nil,
                old_result:   nil,

                match: "skip",
                action: "not run",
                reason: "[#{reason_for_display.upcase}] auto-skip",
                error: nil,

                cmdline: nil,
                folderpath: nil
              }
            )

            log_line(log, "\n")
            next
          end

          # -------------------------
          # 1. Run NEW exe
          # -------------------------

          new_result, new_output, new_actual, new_reason, new_err,
            new_cmd, new_analysis_path, new_levelstat_path =
              run_demo_with_exe(
                exe: "new",
                iwad: iwad_file,
                file_list: final_files,
                demo_path: lmp_path,
                extra_args: extra_args,
                override: override,
                log: log,
                worker_dir: worker_dir
              )

          # --------------------------------------------------------
          # 3. Check unsupported demo format *from NEW exe only*
          # --------------------------------------------------------
          if engine = detect_demo_engine_from_log(new_output)
            log_line(log, yellow("⚠️  Skipping unsupported demo format (#{engine})"))

            local_results << build_result_row(
              base: base_info,
              override: override_info,
              runtime: {
                expected:     nil,

                new_actual:   nil,
                new_result:   nil,

                old_actual:   nil,
                old_result:   nil,

                match: "skip",
                action: "skip",
                reason: "[NOT SUPPORTED: #{engine}]",
                error: nil,

                cmdline: nil,      # skip → no cmdline saved
                folderpath: nil,
              }
            )
            log_line(log, "\n")
            next
          end

          # ❗ ONLY fatal if engine produced invalid argument or similar engine error
          if new_err && new_err =~ /Invalid argument/i
            abort_all!("💥 FATAL ERROR: Invalid argument encountered in NEW exe\n" \
                      "Demo: #{iwadfolder_name}/#{wadfolder_name}/#{demo_name}")
          end

          # print NEW result immediately
          log_line(log,
            case new_result
            when 'pass'    then green("PASS")
            when 'timeout' then red("TIMEOUT")
            else                red("FAIL")
            end
          )
        
          log_line(log, "\n")

          # --- EXPECTED TIME SELECTION ---
          expected_times = extract_expected_times(demo_folder_path)

          expected_sec =
            expected_times.find { |t| new_actual && (t - new_actual.to_i).abs <= 1 } ||
            expected_times.first

          expected_str = seconds_to_dsda_format(expected_sec)

          # --------------------------------------------------------
          # 4. Override action = "override"
          #    If NEW passes, trust the override unless forced levelstat
          #    comparison needs the OLD run too.
          # --------------------------------------------------------
          if override && override[:action].to_s.strip.downcase == "override"
            if new_result == "pass" && !LEVELSTAT_COMPARE
              local_results << build_result_row(
                base: base_info,
                override: override_info,
                runtime: {
                  expected:     expected_str,

                  new_actual:   new_actual,
                  new_result:   new_result,

                  old_actual:   nil,
                  old_result:   nil,

                  match: "pass - match",

                  action: "override",
                  reason: (override[:reason] && !override[:reason].empty?) ? override[:reason] : new_reason,
                  error: new_err,

                  cmdline: nil,
                  folderpath: nil,
                }
              )
              next
            end
          end

          # ---------------------------------------
          # 5. NEW passed → no need to run OLD unless forced levelstat
          # ---------------------------------------
          if new_result == "pass" && !LEVELSTAT_COMPARE
            # Save results and continue
            local_results << build_result_row(
              base: base_info,
              override: override_info,
              runtime: {
                expected:     expected_str,

                new_actual:   new_actual,
                new_result:   new_result,

                old_actual:   nil,
                old_result:   nil,

                match: "pass - match",
                action: nil,
                reason: new_reason,
                error: new_err,

                cmdline: nil,
                folderpath: nil,
              }
            )
            next
          end

          # -------------------------------------------------------------
          # 6. NEW failed normally, or forced levelstat was requested.
          #    Run OLD to check for regressions.
          # -------------------------------------------------------------
          old_result, old_output, old_actual, old_reason, old_err,
            _unused_cmd, old_analysis_path, old_levelstat_path =
              run_demo_with_exe(
                exe: "old",
                iwad: iwad_file,
                file_list: final_files,
                demo_path: lmp_path,
                extra_args: extra_args,
                override: override,
                log: log,
                worker_dir: worker_dir
              )

          # ❗ ONLY fatal if engine produced invalid argument or similar engine error
          if old_err && old_err =~ /Invalid argument/i
            abort_all!("💥 FATAL ERROR: Invalid argument encountered in OLD exe\n" \
                      "Demo: #{iwadfolder_name}/#{wadfolder_name}/#{demo_name}")
          end

          # -------------------------------------------------------------
          # 7. Log NEW result (OLD result is only for comparison)
          # -------------------------------------------------------------
          log_line(log,
            case old_result
            when 'pass' then green('PASS')
            when 'timeout' then red('TIMEOUT')
            else red("FAIL")
          end
          )

          # =============================================================
          # 7. If skip override: show skip banner
          # =============================================================
          if override && override[:action].to_s.strip.downcase == 'skip'
            skip_reason = override[:reason] || '[SKIPPED]'
            log_line(log, yellow("⚠️ Skipped demo #{iwadfolder_name}/#{wadfolder_name}/#{demo_name} (#{skip_reason})"))
          end

          # =============================================================
          # 8. Classify NEW vs OLD result
          # =============================================================
          info = classify_regression(
            new_result:  new_result,
            old_result:  old_result,
            new_reason:  new_reason,
            old_reason:  old_reason,
            override_action: override&.dig(:action)
          )

          levelstat_match = nil
          levelstat_problem = false

          if LEVELSTAT_COMPARE && new_result == "pass" && old_result == "pass"
            levelstat_match = levelstats_match?(new_levelstat_path, old_levelstat_path)

            if levelstat_match
              log_line(log, green("LEVELSTAT PASS 🟢 new/old levelstat matched"))
            else
              levelstat_problem = true
              new_reason = levelstat_match.nil? ? "levelstat comparison missing output" : "levelstat mismatch"
              log_line(log, red("LEVELSTAT FAIL 🔴 #{new_reason}"))

              info = {
                match: "fail - regression",
                ui_message: "FAIL 🔴 regression found (#{new_reason})",
              }
            end
          end

          # Colorize UI message based on match classification
          match_message =
            if info[:match].start_with?("pass") ||
               info[:match] == "skip"
              green(info[:ui_message])
            else
              red(info[:ui_message])
            end

          # Print unified UI message
          log_line(log, match_message)
          log_line(log, "\n")

          # =============================================================
          # 9. Save final aggregated result
          # =============================================================
          is_failure = info[:match].to_s.start_with?("fail")

          if !levelstat_problem && override && override[:reason] && !override[:reason].empty?
            new_reason = override[:reason]
          end

          local_results << build_result_row(
            base: base_info,
            override: override_info,
            runtime: {
              expected:     expected_str,

              new_actual:   new_actual,
              new_result:   new_result,

              old_actual:   old_actual,
              old_result:   old_result,

              match: info[:match],

              action: override&.dig(:action),
              reason: new_reason,
              error: new_err,

              cmdline: is_failure ? new_cmd : nil,
              folderpath: is_failure ? demo_folder_path : nil
            }
          )
          log_line(log, "\n")
          next
        rescue => e
          folder_failed = true
          log_line(log, red("❌ Error in #{iwad}/#{wadname}/#{demo_name}: #{e.class} - #{e.message}"))
          log_line(log, e.backtrace.first(5).join("\n")) if ENV['DEBUG_ERRORS']

          failure_base = base_info || {
            iwadfolder:      env ? env[:iwad_name] : iwad,
            wadfoldername:   env ? env[:wad_name] : wadname,
            demo_foldername: File.basename(demo_folder_path),
            iwad:            env ? env[:iwad_file] : "#{iwad}.wad",
            wadfolder:       env ? env[:wad_name] : wadname,
            wad:             env && env[:primary_wad] ? File.basename(env[:primary_wad]) : nil,
            deh:             env ? normalize_demo_relative_paths(env[:default_dehs], lmp_path).join(", ") : nil,
            demofile:        safe_str(demo_name)
          }

          failure_override = override_info || begin
            failed_override = env && env[:override]
            {
              iwad_override: failed_override&.dig(:iwad_override),
              file_override: failed_override&.dig(:file_override),
              extra_args:    failed_override&.dig(:extra_args),
              comments:      failed_override&.dig(:comments),
              demofolder:    failed_override&.dig(:demofolder)
            }
          end

          local_results << build_result_row(
            base: failure_base,
            override: failure_override,
            runtime: {
              expected: nil,
              new_actual: nil,
              new_result: "fail",
              old_actual: nil,
              old_result: nil,
              match: "fail - setup error",
              action: nil,
              reason: "demo test could not be started",
              error: "#{e.class}: #{e.message}",
              cmdline: nil,
              folderpath: demo_folder_path
            }
          )
        end
      end
      $completed_sets += 1
    end

  rescue => e
    folder_failed = true
    log_line(log, red("❌ Error in WAD #{iwad}/#{wadname}: #{e.class} - #{e.message}"))
    log_line(log, e.backtrace.first(5).join("\n")) if ENV['DEBUG_ERRORS']

  ensure
    failed = folder_failed || local_results.any? { |r| r[:match].to_s.start_with?("fail") }
    colorize = failed ? method(:red) : method(:green)

    duration = Time.now - wad_start_time
    message  = "#{failed ? '❌ FAIL' : '✅ PASS'} - finished WAD #{iwad}/#{wadname} (#{format_duration(duration)})"
    log_line(log, colorize.call(message))

    # Print entire WAD log at once
    $print_mutex.synchronize do
      if SINGLE_FOLDER_MODE
        puts log.join("")   # no leading newline
      else
        puts log.join("\n")   # keep the spacing in normal mode
      end
      puts colorize.call("----------------------------------------------------------------------\n")
    end

    # Mark this WAD complete and print an updated progress snapshot.
    $progress_mutex.synchronize do
      $completed_wads += 1

      if Time.now - $last_progress_time >= 5 && $completed_sets < $total_sets
        $last_progress_time = Time.now
        elapsed     = format_duration(Time.now - global_start_time)
        percent     = ($completed_sets.to_f / [$total_sets, 1].max * 100)
        percent_str = percent.to_i == percent ? percent.to_i.to_s : percent.round(1).to_s
        sets_left   = $total_sets - $completed_sets
        wads_left   = $total_wads - $completed_wads

        $print_mutex.synchronize do
          # puts orange("🟠 Progress: #{$completed_sets} / #{$total_sets} demo folders (#{percent_str}%) - #{elapsed} elapsed")
          puts orange("🟠 Progress: #{sets_left} demo folders, #{wads_left} WADs left (#{percent_str}%) - #{elapsed} elapsed")
          puts orange("----------------------------------------------------------------------\n")
        end
      end
    end

    results_mutex.synchronize { results.concat(local_results) }
  end
end

# ============================================================
# Wait for all threads to settle and print final progress
# ============================================================

percent = ($completed_sets.to_f / [$total_sets, 1].max * 100)
percent_str = percent.to_i == percent ? percent.to_i.to_s : percent.round(1).to_s

puts green("🟢 Finished: #{$completed_sets} / #{$total_sets} demo folders, #{$completed_wads} / #{$total_wads} WADs (#{percent_str}%)")
puts green("----------------------------------------------------------------------\n")

# ============================================================
# Final summary and save results
# ============================================================

total  = results.size
failed = results.count { |r| r[:match].start_with?("fail") }
skipped = results.count { |r| r[:match].to_s == "skip" }
known_skip_reason = lambda do |reason|
  normalized = reason.to_s.downcase
                     .sub(/\A\[/, '')
                     .sub(/\]\s*auto-skip\z/, '')
                     .strip
  SKIP_IMMEDIATE.include?(normalized)
end
failed_only_unresolved_skips = results.count do |r|
  r[:match].to_s == "skip" &&
    r[:action].to_s.strip.downcase != "skip" &&
    !known_skip_reason.call(r[:reason])
end
passed = total - failed

duration = Time.now - global_start_time
percent = (passed.to_f / [total, 1].max * 100)
percent = percent % 1 == 0 ? percent.to_i : percent.round(1)

failed_only_incomplete = FAILED_ONLY && (total == 0 || FAILED_ONLY_UNRESOLVED.any? || failed_only_unresolved_skips > 0)
full_pass = passed == total && !failed_only_incomplete
regressions = results.count { |r| r[:match].include?("regression") }

if full_pass && (regressions == 0)
  puts rainbow("----------------------------------------------------------------------")
  puts rainbow("🏁 Bulk demo regression test passed".center(70))
  puts rainbow("----------------------------------------------------------------------")
else
  puts red("----------------------------------------------------------------------")
  puts red("🏁 Bulk demo regression test failed".center(70))
  puts red("----------------------------------------------------------------------")
end

summary = if full_pass
  green("✅ #{passed} of #{total} demos passed or skipped (#{percent}%)")
else
  red("❌ #{passed} of #{total} demos passed or skipped (#{failed} failed) (#{percent}%)")
end

puts "\n#{summary}"

if FAILED_ONLY && total == 0
  puts red("❌ Failed-only produced no runnable results; keeping 2-failures.csv")
end

if FAILED_ONLY_UNRESOLVED.any?
  puts red("❌ Failed-only could not locate #{FAILED_ONLY_UNRESOLVED.size} demo#{'s' if FAILED_ONLY_UNRESOLVED.size != 1}; keeping 2-failures.csv")
end

if FAILED_ONLY && failed_only_unresolved_skips > 0
  puts yellow("⚠️ Failed-only produced #{failed_only_unresolved_skips} unresolved skipped result#{'s' if failed_only_unresolved_skips != 1}; keeping 2-failures.csv")
end

reg_summary = if regressions == 0
  green("✅ with no regressions")
else
  red("❌ with #{regressions} regression#{'s' if regressions != 1} found")
end

puts "#{reg_summary}\n"

puts "⏱️ Time elapsed: #{format_duration(duration)}\n"
puts "⚙️ Used #{MAX_CORES} of #{TOTAL_CORES} cores\n"

def write_test_state(scope:, port:, status:, failed:, total:, passed:, duration:, regressions:)
  FileUtils.mkdir_p(File.dirname(DSDA.test_state_path))
  File.write(
    DSDA.test_state_path,
    JSON.pretty_generate({
      "updated_at" => Time.now.utc.iso8601,
      "scope" => scope,
      "port" => port,
      "status" => status,
      "failed" => failed,
      "total" => total,
      "passed" => passed,
      "duration" => format_duration(duration),
      "regressions" => regressions
    })
  )
end

write_test_state(
  scope: TEST_SCOPE_LABEL,
  port: TEST_PORT_NAME,
  status: full_pass ? "pass" : "fail",
  failed: failed,
  total: total,
  passed: passed,
  duration: duration,
  regressions: regressions
)

# ============================================================
# Save results to CSV
# ============================================================

sorted = results.sort_by do |r|
  [
    r[:iwad].to_s,
    r[:wadfolder].to_s,
    r[:demo_foldername].to_s,
    r[:demofile].to_s
  ]
end

# ------------------------------
# Unified CSV writer
# ------------------------------
def write_results_csv(sorted, output, merge_failed_only: true)
  # merge failed-only results into existing CSV
  if merge_failed_only && FAILED_ONLY && File.exist?(output)
    merge_failed_rows_into_results(sorted, output)
    return   # we do NOT overwrite the CSV afterward
  end

  # Normal full-run behavior:
  FileUtils.rm_f(output)

  CSV.open(output, 'w') do |csv|
    csv << %w[
      IwadFolder WadFolder DemoFolder
      IWAD WAD Deh DemoFile
      Expected
      NewActual NewResult
      OldActual OldResult
      Match Action Reason Error
      IwadOverride FileOverride ExtraArgs
      Comments Cmdline FolderPath
    ]

    sorted.each do |r|
      csv << [
        auto_quote_rule(r[:iwadfolder]),
        auto_quote_rule(r[:wadfoldername]),
        auto_quote_rule(r[:demo_foldername]),

        r[:iwad].to_s,
        r[:wad].to_s,
        r[:deh].to_s,
        r[:demofile].to_s,

        r[:expected].to_s,

        r[:new_actual].to_s,
        r[:new_result].to_s,

        r[:old_actual].to_s,
        r[:old_result].to_s,

        r[:match].to_s,

        r[:action].to_s,
        r[:reason].to_s,
        r[:error].to_s,

        r[:iwad_override].to_s,
        r[:file_override].is_a?(Array) ? r[:file_override].join(', ') : r[:file_override].to_s,
        in_quotes(r[:extra_args]),

        r[:comments].to_s,
        r[:cmdline].to_s,
        r[:demofolder].to_s
      ]
    end
  end

  puts "📁 Results written to #{output}"
end

# ============================================================
# Unified CSV save for results.csv + failures.csv
# Shared countdown if either file is locked
# ============================================================

def try_save_all_csvs(sorted, failures, preserve_failures: false)
  # Base task list always includes results.csv
  tasks = [
    { name: "results", output: RESULTS_OUTPUT, data: sorted, merge_failed_only: true }
  ]

  # Only add failures.csv if there are real failures
  if failures.any?
    tasks << { name: "failures", output: FAILURES_OUTPUT, data: failures, merge_failed_only: false }
  end

  # Create backups before writing anything
  tasks.each do |t|
    backup_csv(t[:output])
  end

  locked = {}

  # Step 1 — initial save attempt
  tasks.each do |t|
    begin
      write_results_csv(t[:data], t[:output], merge_failed_only: t[:merge_failed_only])
    rescue Errno::EACCES
      locked[t[:name]] = t
    end
  end

  # If nothing is locked → perform cleanup *and then exit*
  if locked.empty?
    if failures.empty? && File.exist?(FAILURES_OUTPUT)
      if preserve_failures
        puts yellow("⚠️ Keeping #{FAILURES_OUTPUT} because failed-only did not fully clear all requested demos")
      else
        backup_csv(FAILURES_OUTPUT)
        FileUtils.rm_f(FAILURES_OUTPUT)
        puts green("🧹 No failures detected — removed #{FAILURES_OUTPUT}")
      end
    end

    return
  end

  puts "\n⚠️  Some CSV files are locked by another program (Excel?)"
  locked.keys.each do |key|
    t = locked[key]
    puts yellow("   • Could not write #{t[:output]}")
  end
  puts

  # Shared Countdown
  countdown_seconds = 180
  countdown_start_time = Time.now
  answer = nil

  retry_interval = 10
  last_retry_time = Time.now

  puts "Would you like to try again? (y/n):"

  # Countdown loop
  while Time.now - countdown_start_time < countdown_seconds
    remaining = countdown_seconds - (Time.now - countdown_start_time).to_i

    time_display =
      if remaining >= 60
        minutes = remaining / 60
        seconds = remaining % 60
        format("%d:%02d", minutes, seconds)
      else
        "#{remaining}s"
      end

    print "\r⏳ Skipping in #{time_display}... "
    $stdout.flush

    # --- user input ---
    if IO.select([$stdin], nil, nil, 1)
      input = $stdin.gets&.strip&.downcase
      if %w[y n].include?(input)
        answer = input
        break
      else
        print "\r" + " " * 60 + "\r"
        puts "\n🤔 Invalid input — please enter 'y' or 'n':"
      end
    end

    # --- automatic retry every 10s ---
    if Time.now - last_retry_time >= retry_interval
      last_retry_time = Time.now

      locked.keys.each do |key|
        t = locked[key]
        begin
          write_results_csv(t[:data], t[:output], merge_failed_only: t[:merge_failed_only])
          locked.delete(key)  # success, remove from locked list
        rescue Errno::EACCES
          # still locked
        end
      end

      # If everything saved during retry → done
      if locked.empty?
        print "\r" + (" " * 60) + "\r"
        return
      end
    end
  end

  # User gave no input — countdown expired
  unless answer
    print "\r⌛ Time expired.           \n"
    answer = 'timeout'
  end

  # ------------------------------
  # Final resolution
  # ------------------------------
  case answer
  when 'y'
    # Final retry attempt
    locked.keys.each do |key|
      t = locked[key]
      begin
        write_results_csv(t[:data], t[:output], merge_failed_only: t[:merge_failed_only])
        locked.delete(key)
      rescue Errno::EACCES
      end
    end
  end

  # If still locked, write to alternate filenames
  locked.each do |key, t|
    duplicate = csv_next_numbered_filename(t[:output])
    write_results_csv(t[:data], duplicate, merge_failed_only: t[:merge_failed_only])
    puts yellow("📁 #{t[:output]} locked → wrote #{duplicate} instead")
  end
end


# ============================================================
# RUN unified save logic
# ============================================================

failures = sorted.select { |r| r[:match].to_s.start_with?("fail") }
try_save_all_csvs(sorted, failures, preserve_failures: failed_only_incomplete)

puts "\n\n"
