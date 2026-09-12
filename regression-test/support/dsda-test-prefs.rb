# frozen_string_literal: true

# Core build path
BUILD_PATH = File.expand_path('../build', __dir__)

# Ports available in dsda-start
PORTS = {
  'dsda-doom' => {
    nickname: 'dsda',
    exe: File.join(BUILD_PATH, 'dsda-doom', 'dsda-doom.exe'),
    old_exe: File.join(BUILD_PATH, 'old', 'dsda-doom', 'dsda-doom.exe')
  },
  'nyan-doom' => {
    nickname: 'nyan',
    exe: File.join(BUILD_PATH, 'nyan-doom', 'nyan-doom.exe'),
    old_exe: File.join(BUILD_PATH, 'old', 'dsda-doom', 'dsda-doom.exe')
  }
}.freeze

DEFAULT_PORT = 'dsda-doom'
PORT_STATE_PATH = File.expand_path('../cache/port_state.json', __dir__)

# default port settings
# dsda-test replaces them with the globally selected port (or explicit command-line overrides)
EXE_PATH     = PORTS.fetch(DEFAULT_PORT).fetch(:exe)
OLD_EXE_PATH = PORTS.fetch(DEFAULT_PORT).fetch(:old_exe)

# Core data paths
IWAD_WAD_PATH       = File.expand_path('wads/', __dir__)
EXTRA_WAD_PATH      = File.expand_path('wads/EX/', __dir__)
COMMERCIAL_WAD_PATH = File.expand_path('wads/EX/CM/', __dir__)
MASTER_LEVELS_PATH  = File.expand_path('wads/EX/CM/ML/', __dir__)

# Demo locations + tmp workspace
DEMOS_ROOT       = File.expand_path('demos', __dir__)
TMP_ROOT         = File.expand_path('cache/tmp', __dir__)

# Override file
OVERRIDE_IMPORT  = File.expand_path("../overrides.csv", __dir__)

# Output files
CSV_OUTPUT       = File.expand_path('../data-export/results.csv', __dir__)
FAILURES_OUTPUT  = File.expand_path('../data-export/failures.csv', __dir__)

# Defaults
DEFAULT_IWAD     = 'doom2.wad'
TIMEOUT_SECS     = 900
HEARTBEAT_SECS   = 30

# Known broken demo ZIPs from DSDA that should not be downloaded/extracted.
# Keys may be scoped as "iwad/wad/zipname.zip" or global as "zipname.zip".
EXCLUDED_DEMO_ZIPS = {
  "doom2/doom2/peter_nm100s.zip" => "Known broken ZIP on DSDA server",
}.freeze

# Known commercial/master-level WAD defaults.
# CSV FileOverride entries still win when a demo needs a specific exception.
AUTO_FILE_OVERRIDES = {
  "hexen/hexdd"         => ["CM/hexdd.wad"],
  "doom2/hell2pay"      => ["CM/HTP-RAW.WAD"],
  "doom2/id1"           => ["CM/id1.wad"],
  "doom2/nerve"         => ["CM/nerve.wad"],
  "doom2/one-humanity"  => ["CM/one-humanity.wad"],

# Master Levels
  "doom2/attack_ml"   => ["ML/ATTACK.WAD"],
  "doom2/blacktwr"    => ["ML/BLACKTWR.WAD"],
  "doom2/bloodsea"    => ["ML/BLOODSEA.WAD"],
  "doom2/canyon_ml"   => ["ML/CANYON.WAD"],
  "doom2/catwalk"     => ["ML/CATWALK.WAD"],
  "doom2/combine"     => ["ML/COMBINE.WAD"],
  "doom2/fistula"     => ["ML/FISTULA.WAD"],
  "doom2/garrison"    => ["ML/GARRISON.WAD"],
  "doom2/geryon"      => ["ML/GERYON.WAD"],
  "doom2/manor_ml"    => ["ML/MANOR.WAD"],
  "doom2/mephisto"    => ["ML/MEPHISTO.WAD"],
  "doom2/minos"       => ["ML/MINOS.WAD"],
  "doom2/nessus"      => ["ML/NESSUS.WAD"],
  "doom2/paradox_ml"  => ["ML/PARADOX.WAD"],
  "doom2/subspace"    => ["ML/SUBSPACE.WAD"],
  "doom2/subterra"    => ["ML/SUBTERRA.WAD"],
  "doom2/teeth"       => ["ML/TEETH.WAD"],
  "doom2/ttrap"       => ["ML/TTRAP.WAD"],
  "doom2/vesperas"    => ["ML/VESPERAS.WAD"],
  "doom2/vergil"      => ["ML/VERGIL.WAD"],

# Special Pwads
  "doom2/eviternityii" => ["EX/Eviternity II.wad"],
  "doom2/junkfood4"    => ["EX/Junkfood4.wad"],
}.freeze

# Known folders whose demos are unsupported as a group.
# The value is written to Comments; the result reason stays "unsupported".
AUTO_FILE_UNSUPPORTED = {
  "hexen/hexen10" => "Hexen 1.0",
  "heretic/heretic10" => "Heretic 1.0",
}.freeze

# Amount of CPU cores to use (default: 50% of total)
PERCENT_OF_CORES = 0.50

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
