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
    id, department: nil, group: nil, department_name: nil, group_name: nil, daily_sending: nil,
    pair_sending: nil, **
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
  end
  attr_accessor :id, :state,
    :group, :group_name, :department, :department_name,
    :daily_sending, :pair_sending,
    :departments, :groups, :department_name_temp, :department_url

  def zaochnoe?
    @department_name == 'заочное обучение'
  end

  def group_info
    {sid: @department, gr: @group, group: @group_name, department: @department_name,
     zaochnoe: zaochnoe?}
  end

  def to_h
    {department:, department_name:, group:, group_name:, daily_sending:, pair_sending:}
  end

  def to_json(*)
    to_h.to_json
  end
end
