# frozen_string_literal: true

module Raspishika
  class Chat < ActiveRecord::Base
    has_many :command_usages, dependent: :destroy
    has_many :recent_teachers, dependent: :destroy
    validates :tg_id, presence: true, uniqueness: true
    validates :username, uniqueness: true, allow_nil: true
  end
end
