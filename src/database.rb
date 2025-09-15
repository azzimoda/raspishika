# frozen_string_literal: true

require 'active_record'
require 'fileutils'

require_relative 'logger'

module Raspishika
  DB_FILE = File.expand_path '../data/db.sqlite3', __dir__
  BACKUP_DIR = File.expand_path '../data/backups', __dir__

  def self.backup_database
    FileUtils.mkdir_p BACKUP_DIR
    timestamp = Time.now.strftime '%Y-%m-%d_%H-%M-%S'
    backup_file = File.join BACKUP_DIR, "db_backup_#{timestamp}.sqlite3"
    FileUtils.cp DB_FILE, backup_file
    logger.info "Database backup saved to #{backup_file}"
  end

  ActiveRecord::Base.establish_connection(
    adapter: 'sqlite3',
    database: DB_FILE
  )

  ActiveRecord::Schema.define do
    create_table :chats, if_not_exists: true do |t|
      t.string :tg_id, null: false
      t.string :username

      t.string :department
      t.string :group
      t.string :daily_sending_time
      t.boolean :pair_sending, default: false

      t.timestamps
    end
    add_index :chats, :tg_id, if_not_exists: true, unique: true
    add_index :chats, :username, if_not_exists: true, unique: true

    create_table :command_usages, if_not_exists: true do |t|
      t.references :chat, null: false, foreign_key: true
      t.string :command, null: false
      t.boolean :successful, default: true
      t.float :response_time, null: false # seconds

      t.timestamps
    end
    add_index :command_usages, :command, if_not_exists: true
    add_index :command_usages, :created_at, if_not_exists: true

    create_table :recent_teachers, if_not_exists: true do |t|
      t.references :chat, null: false, foreign_key: true
      t.string :name, null: false

      t.timestamps
    end
  end
end

Dir[File.expand_path('./models/*.rb', __dir__)].each { require it }
