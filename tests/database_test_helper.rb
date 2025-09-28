# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/spec'
require 'fileutils'

require_relative '../src/config'

Raspishika::Config[:database][:file] = 'tests/data/test_db.sqlite3'
FileUtils.mkdir_p File.dirname(Raspishika::Config[:database][:file])
FileUtils.remove_file Raspishika::Config[:database][:file] if File.exist? Raspishika::Config[:database][:file]

require_relative '../src/database'
