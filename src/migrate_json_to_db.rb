# frozen_string_literal: true

require 'logger'

require_relative 'database'
Dir[File.expand_path('./models/*.rb', __dir__)].each { require it }
require_relative 'user'

module Raspishika
  class JsonToDbMigrator
    include GlobalLogger

    def initialize(file = User::USERS_FILE)
      User.load file
      @json_data = User.users
    end

    def migrate
      logger.info 'Migrating data from JSON to DB...'

      @json_data.each { |chat_id, chat_data| migrate_chat chat_id, chat_data }
    end

    private

    def migrate_chat(chat_id, chat_data)
      chat = Chat.find_or_initialize_by(tg_id: chat_id)

      chat.assign_attributes(
        username: chat_data.username,
        department: chat_data.department_name,
        group: chat_data.group_name,
        daily_sending_time: chat_data.daily_sending,
        pair_sending: chat_data.pair_sending.then { it.nil? ? false : it },
        created_at: chat_data.statistics[:start]
      )

      if chat.save
        migrate_recent_teacher chat, chat_data.recent_teachers
        migrate_command_usages chat, chat_data.statistics[:last_commands]
        logger.info "Chat #{chat_id} migrated successfully"
      else
        logger.error "Chat #{chat_id} migration failed: #{chat.errors.full_messages}"
      end
    end

    def migrate_recent_teacher(chat, recent_teachers)
      return unless recent_teachers.is_a? Array

      recent_teachers.first(6).each do |teacher_name|
        chat.recent_teachers.create(name: teacher_name.to_s)
      end
    end

    def migrate_command_usages(chat, last_commands)
      return unless last_commands.is_a? Array

      last_commands.each do |command_data|
        chat.command_usages.create(
          command: command_data[:command],
          successful: command_data[:ok],
          response_time: command_data[:response_time] || 0,
          created_at: Time.at(command_data[:timestamp])
        )
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  migrator = Raspishika::JsonToDbMigrator.new(File.expand_path('../data/users.json', __dir__))
  migrator.migrate
end
