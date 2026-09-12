# frozen_string_literal: true

require 'json'
require_relative 'dsda-test-prefs'

PORTS_CONFIG_PATH = File.join(PORTS_PATH, 'ports.json')
PORTS = JSON.parse(File.read(PORTS_CONFIG_PATH)).transform_values do |port|
  {
    nickname: port.fetch('nickname'),
    exe: File.expand_path(port.fetch('exe'), PORTS_PATH),
    old_exe: File.expand_path(port.fetch('old_exe'), PORTS_PATH)
  }
end.freeze

# dsda-test replaces these with the selected port or explicit command-line overrides
EXE_PATH     = PORTS.fetch(DEFAULT_PORT).fetch(:exe)
OLD_EXE_PATH = PORTS.fetch(DEFAULT_PORT).fetch(:old_exe)
