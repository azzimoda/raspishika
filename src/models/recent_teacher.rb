# frozen_string_literal: true

module Raspishika
  class RecentTeacher < ActiveRecord::Base
    belongs_to :chat
    validates :name, presence: true
    validate :max_six_teachers_per_chat

    private

    def max_six_teachers_per_chat
      return unless chat.recent_teachers.count >= 6

      errors.add(:name, 'Cannot have more that 6 recent teachers per chat.')
    end
  end
end
