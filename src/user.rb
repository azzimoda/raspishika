require 'json'
require 'time'

module Raspishika
  class User
    BACKUP_FILE = File.expand_path('../data/users.json', __dir__)
    TEMP_FILE = File.expand_path('../data/cache/users.json.tmp', __dir__)
  
    @users = {}
    @logger = nil
    @mutex = Mutex.new
  
    class << self
      attr_accessor :logger, :users
  
      def [] id
        @mutex.synchronize { @users[id.to_s] ||= new id.to_s }
      end
  
      def delete user
        @mutex.synchronize { @users.delete_if { |id, _| id == user.id } }
      end

      def backup
        @users.select! { |id, user| user.department && user.group }

        FileUtils.mkdir_p File.dirname TEMP_FILE
        FileUtils.mkdir_p File.dirname BACKUP_FILE
  
        File.write(TEMP_FILE, JSON.dump(@users))
        logger.debug "Temporary backed up #{@users.size} users to #{TEMP_FILE}"
  
        FileUtils.mv(TEMP_FILE, BACKUP_FILE)
        logger.info "Backed up #{@users.size} users to #{BACKUP_FILE}"
      rescue => e
        logger.error "Backup failed: #{e.message}"
        raise
      end
  
      def restore
        logger&.info "Restoring users..."
        data = JSON.parse(File.read(BACKUP_FILE), symbolize_names: true).transform_keys(&:to_s)
        @users = data.map { |id, data| [id.to_s, new(id, **data)] }.to_h
        @users.each_value do |user|
          user.statistics[:start] = Time.parse user.statistics[:start] if user.statistics[:start]
          user.statistics[:last_commands]&.each { it[:timestamp] = Time.parse it[:timestamp] }
          user.statistics[:daily_sendings]&.each { it[:timestamp] = Time.parse it[:timestamp] }
          user.statistics[:pair_sendings]&.each { it[:timestamp] = Time.parse it[:timestamp] }
        end
        logger&.info "Restored #{@users.size} users"
      rescue Errno::ENOENT, JSON::ParserError => e
        logger&.error "Failed to restore users: #{e.detailed_message}"
        @users = {}
      end
    end
  
    def initialize(
      id, department: nil, group: nil, department_name: nil, group_name: nil, daily_sending: nil,
      pair_sending: nil, statistics: nil, **
    )
      @id = id
      @state = :default
  
      @department = department
      @department_name = department_name
      @group = group
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
    end
    attr_accessor :id, :state,
      :group, :group_name, :department, :department_name,
      :daily_sending, :pair_sending,
      :departments, :groups, :department_name_temp, :department_url,
      :statistics
    
    def private?
      # TODO: Understand why id is a string, and is it a string always.
      id.to_s.to_i.positive?
    end

    def supergroup?
      id.to_s.to_i.negative?
    end
  
    def zaochnoe?
      @department_name == 'заочное обучение'
    end
  
    def group_info
      {sid: @department, gr: @group, group: @group_name, department: @department_name,
       zaochnoe: zaochnoe?}
    end
  
    def to_h
      {department:, department_name:, group:, group_name:, daily_sending:, pair_sending:, statistics:}
    end
  
    def to_json(*)
      to_h.to_json
    end
  
    def push_command_usage command:, ok: true, timestamp: Time.now
      User.logger&.debug "Pushing command usage for user #{id}: #{command}"
      @statistics[:last_commands].tap do |last_commands|
        last_commands << { command:, ok:, timestamp: }
        last_commands.shift [0, last_commands.size - 100].max
      end
    end
  
    def push_daily_sending_report conf_time:, process_time:, ok: true, timestamp: Time.now
      User.logger&.debug "Pushing daily sending report for user #{id}: #{conf_time} #{process_time} #{ok}"
      @statistics[:daily_sendings].tap do |daily_sendings|
        daily_sendings << { conf_time:, process_time:, ok:, timestamp: }
        daily_sendings.shift [0, daily_sendings.size - 100].max
      end
    end
  
    def push_pair_sending_report process_time:, ok: true, timestamp: Time.now
      User.logger&.debug "Pushing pair sending report for user #{id}: #{process_time} #{ok}"
      @statistics[:pair_sendings].tap do |pair_sendings|
        pair_sendings << { process_time:, ok:, timestamp: }
        pair_sendings.shift [0, pair_sendings.size - 100].max
      end
    end
  end
end
