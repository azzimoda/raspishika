class User
  BACKUP_FILE = '.data/users.json'

  @users = {}
  @logger = nil

  class << self
      attr_accessor :logger, :users

      def [] id
        @users[id.to_s] ||= new
      end

      def backup
        FileUtils.mkdir_p File.dirname BACKUP_FILE
        File.write(BACKUP_FILE, JSON.dump(@users))
      end

      def restore
        data = JSON.parse File.read BACKUP_FILE
        @users = data.transform_values { |data| new(**data) }
      rescue Errno::ENOENT, JSON::ParserError => e
        @logger&.error "Failed to restore users: #{e.detailed_message}"
        @users = {}
      end
  end

  def initialize group: nil, timer: nil, **_
    @state = :default
    # like '437' or nil
    @group = group
    # like { type: :once, time: '18:00' } or { type: :before } or nil
    @timer = timer
    @departments = []
    @department = nil
    @department_url = nil
    @groups = []
    @temp_group = nil
  end
  attr_accessor :state, :group, :timer, :departments, :department, :department_url, :groups, :temp_group

  def to_h
    {state: @state, group: @group, timer: @timer}.compact
  end
end
