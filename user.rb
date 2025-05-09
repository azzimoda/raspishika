class User
  BACKUP_FILE = '.data/users.json'

  @users = {}
  @logger = nil

  class << self
    attr_accessor :logger, :users

    def [] id
      logger&.info "New user: #{id}" unless @users[id.to_s]
      @users[id.to_s] ||= new id.to_s
    end

    def delete user
      @users.delete_if { |id, _| id == user.id }
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

  def initialize(id, department: nil, group: nil, group_name: nil, timer: nil)
    @id = id
    @state = :default
    @department = department
    @group = group
    @group_name = group_name
    # like { type: :once, time: '18:00' } or { type: :before } or nil
    @timer = timer
    @departments = []
    @groups = []
    @department_url = nil
    @temp_group = nil
  end
  attr_accessor :id, :state, :group, :group_name, :timer, :departments,
    :department, :department_url, :groups, :temp_group

  def group_info
    {sid: @department, gr: @group}
  end

  def to_h
    {department: @department, group: @group, group_name: @group_name, timer: @timer}
  end
  
  def to_json(*)
    to_h.to_json
  end
end
