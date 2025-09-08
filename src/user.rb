# frozen_string_literal: true

require 'json'
require 'time'

module Raspishika
  class User
    module State
      DEFAULT = :default
      SELECTING_DEPARTMENT = :selecting_department
      SELECTING_DEPARTMENT_QUICK = :selecting_department_quick
      SELECTING_GROUP = :selecting_group
      SELECTING_GROUP_QUICK = :selecting_group_quick
      SELECTING_QUICK_SCHEDULE = :selecting_quick_schedule
      SELECTING_TEACHER = :selecting_teacher
      SETTINGS = :settings
      SETTING_DAILY_SENDING = :setting_daily_sending
    end

    BACKUP_FILE = File.expand_path('../data/users.json', __dir__)
    TEMP_FILE = File.expand_path('../data/cache/users.json.tmp', __dir__)

    @users = {}
    @logger = nil
    @mutex = Mutex.new

    class << self
      attr_accessor :logger, :users

      def [](id, username: nil)
        @mutex.synchronize { (@users[id.to_s] ||= new id.to_s, username: username).tap { it.username ||= username } }
      end

      def delete(user)
        @mutex.synchronize { @users.delete_if { |id, _| id == user.id } }
      end

      # TODO: Migrate to SQLite or PStore.
      def save_all
        return if @users.empty?

        users = @users.select { |_, user| user.department_name && user.group_name }

        FileUtils.mkdir_p File.dirname TEMP_FILE
        FileUtils.mkdir_p File.dirname BACKUP_FILE

        File.write(TEMP_FILE, users.to_json)
        logger.debug "Temporary backed up #{users.size} users to #{TEMP_FILE}"

        FileUtils.mv(TEMP_FILE, BACKUP_FILE)
        logger.info "Backed up #{users.size} users to #{BACKUP_FILE}"
      rescue StandardError => e
        logger.error "Backup failed: #{e.message}"
        raise
      end

      def load
        logger&.info 'Loading chats...'
        data = JSON.parse(File.read(BACKUP_FILE), symbolize_names: true).transform_keys(&:to_s)
        @users = data.map { |id, data| [id.to_s, new(id, **data)] }.to_h
        @users.each_value do |user|
          user.statistics[:start] = Time.parse user.statistics[:start] if user.statistics[:start]
          user.statistics[:last_commands]&.each { it[:timestamp] = Time.parse it[:timestamp] }
          user.statistics[:daily_sendings]&.each { it[:timestamp] = Time.parse it[:timestamp] }
          user.statistics[:pair_sendings]&.each { it[:timestamp] = Time.parse it[:timestamp] }
        end
        logger&.info "Loaded #{@users.size} chats"
      rescue Errno::ENOENT, JSON::ParserError => e
        logger&.error "Failed to load users: #{e.detailed_message}"
        @users = {}
      end
    end

    def initialize(
      id, username: nil, department_name: nil, group_name: nil, daily_sending: nil, pair_sending: nil, statistics: nil,
      recent_groups: [], recent_teachers: [], **
    )
      @id = id
      @username = username

      @state = :default

      @department_name = department_name
      @group_name = group_name

      @daily_sending = daily_sending
      @pair_sending = pair_sending

      @departments = []
      @groups = {}
      @department_name_temp = nil
      @department_url = nil

      @statistics = statistics || {}
      @statistics[:last_commands] ||= []
      @statistics[:daily_sendings] ||= []
      @statistics[:pair_sendings] ||= []

      @recent_groups = recent_groups
      @recent_teachers = recent_teachers
    end
    attr_accessor :id, :username, :state,
                  :group_name, :department_name,
                  :daily_sending, :pair_sending,
                  :departments, :groups, :department_name_temp, :department_url,
                  :statistics
    attr_reader :recent_groups, :recent_teachers

    def default?
      state == State::DEFAULT
    end

    def selecting_department?
      [State::SELECTING_DEPARTMENT, State::SELECTING_DEPARTMENT_QUICK].include? state
    end

    def selecting_group?
      [State::SELECTING_GROUP, State::SELECTING_GROUP_QUICK].include? state
    end

    def selecting_quick?
      [State::SELECTING_DEPARTMENT_QUICK, State::SELECTING_GROUP_QUICK].include? state
    end

    def quick_schedule?
      state == State::SELECTING_QUICK_SCHEDULE
    end

    def selecting_teacher?
      state == State::SELECTING_TEACHER
    end

    def settings?
      state == State::SETTINGS
    end

    def setting_daily_sending?
      state == State::SETTING_DAILY_SENDING
    end

    def private?
      id.to_s.to_i.positive?
    end

    def supergroup?
      id.to_s.to_i.negative?
    end

    def zaochnoe?
      @department_name == 'заочное обучение'
    end

    def group_info
      { group: @group_name, department: @department_name, zaochnoe: zaochnoe? }
    end

    def to_h
      { username: username, department_name: department_name, group_name: group_name, daily_sending: daily_sending,
        pair_sending: pair_sending, statistics: statistics, recent_teachers: recent_teachers,
        recent_groups: recent_groups }
    end

    def to_json(*)
      to_h.to_json
    end

    def push_command_usage(command:, ok: true, timestamp: Time.now)
      User.logger&.debug "Pushing command usage for user #{id}: #{command}"
      @statistics[:last_commands].tap do |last_commands|
        last_commands << { command: command, ok: ok, timestamp: timestamp }
        last_commands.shift [0, last_commands.size - 100].max
      end
    end

    def push_daily_sending_report(conf_time:, process_time:, ok: true, timestamp: Time.now)
      User.logger&.debug "Pushing daily sending report for user #{id}: #{conf_time} #{process_time} #{ok}"
      @statistics[:daily_sendings].tap do |daily_sendings|
        daily_sendings << { conf_time: conf_time, process_time: process_time, ok: ok, timestamp: timestamp }
        daily_sendings.shift [0, daily_sendings.size - 100].max
      end
    end

    def push_pair_sending_report(process_time:, ok: true, timestamp: Time.now)
      User.logger&.debug "Pushing pair sending report for user #{id}: #{process_time} #{ok}"
      @statistics[:pair_sendings].tap do |pair_sendings|
        pair_sendings << { process_time: process_time, ok: ok, timestamp: timestamp }
        pair_sendings.shift [0, pair_sendings.size - 100].max
      end
    end

    def push_recent_group(gname)
      @recent_groups.unshift gname
      @recent_groups = @recent_groups.uniq.first 6
    end

    def push_recent_teacher(tname)
      @recent_teachers.unshift tname
      @recent_teachers = @recent_teachers.uniq.first 6
    end
  end
end
