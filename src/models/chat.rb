# frozen_string_literal: true

module Raspishika
  class Chat < ActiveRecord::Base
    has_many :command_usages, dependent: :destroy
    has_many :recent_teachers, dependent: :destroy
    validates :tg_id, presence: true, uniqueness: true
    validates :username, uniqueness: true, allow_nil: true

    def private?
      tg_id[0] != '-'
    end

    def add_recent_teacher(name)
      recent_teachers.select { it.name.downcase == name.downcase }.each(&:destroy)
      recent_teachers.order(created_at: :asc).first.destroy if recent_teachers.count >= 6

      recent_teachers.create name: name
    end

    def log_command_usage(command, successful, response_time)
      command_usages.create(command: command, successful: successful, response_time: response_time)
    end

    def group_info
      { department: department, group: group }
    end
  end
end
