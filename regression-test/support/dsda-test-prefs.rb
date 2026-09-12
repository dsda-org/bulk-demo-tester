# frozen_string_literal: true
require 'json'

# ports path
PORTS_PATH = File.expand_path('../ports', __dir__)

# load settings file
SETTINGS_PATH = File.expand_path('settings.json', __dir__)
SETTINGS = JSON.parse(File.read(SETTINGS_PATH))

# Defaults
DEFAULTS = SETTINGS.fetch('defaults')
DEFAULT_PORT   = DEFAULTS.fetch('port')
DEFAULT_IWAD   = DEFAULTS.fetch('iwad')
TIMEOUT_SECS   = DEFAULTS.fetch('timeout_secs')

# Amount of CPU cores to use (default: 50% of total)
CPU_CORE_PERCENT = DEFAULTS.fetch('cpu_core_percent')
unless CPU_CORE_PERCENT.between?(0.0, 1.0)
  raise ArgumentError, 'defaults.cpu_core_percent must be between 0.0 and 1.0'
end

# test state paths
CACHE_PATH = File.expand_path('cache', __dir__)
DEMO_INDEX_PATH = File.join(CACHE_PATH, 'demo_index.json')
SYNC_STATE_PATH = File.join(CACHE_PATH, 'sync_state.json')
TEST_STATE_PATH = File.join(CACHE_PATH, 'test_state.json')

# sync paths
SYNC_WARNING_PATH = File.expand_path('../dsda-sync-warning.txt', __dir__)

# Core data paths
IWAD_WAD_PATH       = File.expand_path('wads/', __dir__)
EXTRA_WAD_PATH      = File.expand_path('wads/EX/', __dir__)
COMMERCIAL_WAD_PATH = File.expand_path('wads/EX/CM/', __dir__)
MASTER_LEVELS_PATH  = File.expand_path('wads/EX/CM/ML/', __dir__)

# Demo locations + tmp workspace
DEMOS_ROOT        = File.expand_path('demos', __dir__)
DEMOS_CACHE_ROOT  = File.join(CACHE_PATH, 'tmp')

# CSV Overrides / Output files
DATA_CSV_PATH = File.expand_path('../csv', __dir__)

OVERRIDE_IMPORT  = File.join(DATA_CSV_PATH, '0-overrides.csv')
RESULTS_OUTPUT   = File.join(DATA_CSV_PATH, '1-results.csv')
FAILURES_OUTPUT  = File.join(DATA_CSV_PATH, '2-failures.csv')

RESULTS_BACKUP_PATH  = File.join(DATA_CSV_PATH, 'BU-results')
FAILURES_BACKUP_PATH = File.join(DATA_CSV_PATH, 'BU-failures')

# Known broken demo ZIPs from DSDA that should not be downloaded/extracted.
# Keys may be scoped as "iwad/wad/zipname.zip" or global as "zipname.zip".
EXCLUDED_DEMO_ZIPS   = SETTINGS.fetch('excluded_demo_zips').freeze

# Known commercial/master-level WAD defaults.
# CSV FileOverride entries still win when a demo needs a specific exception.
# Examples: Commercial Wads, Master Levels, Special Pwads (Eviternity II, Junkfood 4)
AUTO_FILE_OVERRIDES  = SETTINGS.fetch('auto_file_overrides').freeze

# Known folders whose demos are unsupported as a group.
# The value is written to Comments; the result reason stays "unsupported".
# Example: Heretic 1.0, Hexen 1.0
AUTO_FILE_UNSUPPORTED = SETTINGS.fetch('auto_file_unsupported').freeze


module Utility
  extend self

  class Analysis
    def initialize(path = "analysis.txt")
      @path = path

      unless File.exist?(@path)
        @data = {}
        return
      end

      @data = Hash[
        File.readlines(@path, chomp: true).map(&:split).map do |a|
          [a[0], a[1..].join(' ')]
        end
      ]
    end

    def skill
      @data['skill'].to_i
    end

    def nomonsters?
      @data['nomonsters'] == '1'
    end

    def respawn?
      @data['respawn'] == '1'
    end

    def fast?
      @data['fast'] == '1'
    end

    def pacifist?
      @data['pacifist'] == '1'
    end

    def stroller?
      @data['stroller'] == '1'
    end

    def reality?
      @data['reality'] == '1'
    end

    def almost_reality?
      @data['almost_reality'] == '1'
    end

    def hundred_k?
      @data['100k'] == '1'
    end

    def hundred_s?
      @data['100s'] == '1'
    end

    def missed_monsters
      @data['missed_monsters'].to_i
    end

    def missed_secrets
      @data['missed_secrets'].to_i
    end

    def tyson_weapons?
      @data['tyson_weapons'] == '1'
    end

    def turbo?
      @data['turbo'] == '1'
    end

    def weapon_collector?
      @data['weapon_collector'] == '1'
    end

    def category
      @data['category']
    end
  end

  class Levelstat
    def initialize(filename)
      @data = File.readlines(filename, chomp: true).map(&:split)
    end

    def rows
      @data
    end

    def total
      return '00:00' unless @data.last

      raw = @data.last.join(' ')

      # Extract the time inside parentheses, e.g. (14:49)
      time = raw[/\(\s*(\d{1,3}:\d{2})\s*\)/, 1]

      # Fallback just in case it's missing
      time ||= '00:00'

      time
    end
  end
end
