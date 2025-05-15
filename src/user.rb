class User
  BACKUP_FILE = File.join('data', 'users.json')

  @users = {}
  @logger = nil
  @mutex = Mutex.new

  class << self
    attr_accessor :logger, :users

    def [] id
      @mutex.synchronize do
        logger&.info "New user: #{id}" unless @users[id.to_s]
        @users[id.to_s] ||= new id.to_s
      end
    end

    def delete user
      @mutex.synchronize { @users.delete_if { |id, _| id == user.id } }
    end

    def backup
      FileUtils.mkdir_p File.dirname BACKUP_FILE
      File.write(BACKUP_FILE, JSON.dump(@users))
      logger.info "Backed up #{@users.size} users to #{BACKUP_FILE}"
    end

    def restore
      logger&.info "Restoring users..."
      data = JSON.parse(File.read(BACKUP_FILE), symbolize_names: true).transform_keys(&:to_s)
      @users = data.map { |id, data| [id.to_s, new(id, **data)] }.to_h
      logger&.info "Restored #{@users.size} users"
    rescue Errno::ENOENT, JSON::ParserError => e
      logger&.error "Failed to restore users: #{e.detailed_message}"
      @users = {}
    end
  end

  def initialize(
    id, department: nil, group: nil, group_name: nil, daily_sending: nil, pair_sending: nil,
    last_sent_date: nil, **
  )
    @id = id
    @state = :default
    @department = department
    @group = group
    @group_name = group_name
    @daily_sending = daily_sending
    @pair_sending = pair_sending
    @last_sent_date = nil
    @departments = []
    @groups = {}
    @department_url = nil
    @temp_group = nil
  end
  attr_accessor :id, :state, :group, :group_name, :daily_sending, :pair_sending, :last_sent_date,
    :departments, :department, :department_url, :groups, :temp_group, :z

  def z?
    @z
  end

  def group_info
    {sid: @department, gr: @group, group: @group_name, z:}
  end

  def to_h
    {department:, group:, group_name:, daily_sending:, pair_sending:, last_sent_date:}
  end

  def to_json(*)
    to_h.to_json
  end
end
