class User
  BACKUP_FILE = '.data/users.json'

  @users = {}
  @logger = nil

  class << self
    attr_accessor :logger, :users

    def [] id
      logger&.info "New user: #{id}" unless @users[id.to_s]
      @users[id.to_s] ||= new
    end

    def backup
      FileUtils.mkdir_p File.dirname BACKUP_FILE
      File.write(BACKUP_FILE, JSON.dump(@users))
      logger.info "Backed up #{@users.size} users to #{BACKUP_FILE}"
    end

    def restore
      logger&.info "Restoring users..."
      data = JSON.parse(File.read(BACKUP_FILE), symbolize_names: true).transform_keys(&:to_s)
      @users = data.transform_values { |data| new(**data) }
      logger&.info "Restored #{@users.size} users"
    rescue Errno::ENOENT, JSON::ParserError => e
      logger&.error "Failed to restore users: #{e.detailed_message}"
      @users = {}
    end
  end

  def initialize(department: nil, group: nil, timer: nil)
    @state = :default
    @department = department
    @group = group
    # like { type: :once, time: '18:00' } or { type: :before } or nil
    @timer = timer
    @departments = []
    @groups = []
    @department_url = nil
    @temp_group = nil
  end
  attr_accessor :state, :group, :timer, :departments, :department, :department_url, :groups, :temp_group

  def group_info
    {sid: @department, gr: @group}
  end

  def to_h
    {department: @department, group: @group, timer: @timer}
  end
  
  def to_json(*)
    to_h.to_json
  end
end
