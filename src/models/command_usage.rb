# frozen_string_literal: true

module Raspishika
  class CommandUsage < ActiveRecord::Base
    belongs_to :chat
    validates :command, presence: true
    validates :response_time, presence: true
  end
end
