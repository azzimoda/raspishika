# frozen_string_literal: true

require_relative 'cache'

module Raspishika
  class Session
    module State
      DEFAULT = :default
      SELECTING_DEPARTMENT = :selecting_department
      SELECTING_DEPARTMENT_QUICK = :selecting_department_quick
      SELECTING_GROUP = :selecting_group
      SELECTING_GROUP_QUICK = :selecting_group_quick
      SELECTING_QUICK_SCHEDULE = :selecting_quick_schedule
      SELECTING_TEACHER = :selecting_teacher
      SETTINGS = :settings
      SETTING_DAILY_SENDING = :setting_daily_sending
    end

    SESSION_TTL = 24 * 60 * 60

    class << self
      def [](chat)
        chat_id =
          if chat.is_a? Chat then chat.tg_id
          elsif chat.is_a? String then chat
          else
            raise ArgumentError, "Expected a Chat instance or a String, but got: #{chat.inspect} (#{chat.class})"
          end
        cache_key = :"chat_#{chat_id}"
        chat_session = Cache.get cache_key, expires_in: SESSION_TTL

        chat_session || Cache.set(cache_key, new(chat_id))
      end
    end

    attr_reader :chat_id
    attr_accessor :state, :departments, :groups, :department_name_temp, :department_url

    def initialize(chat_id, **data)
      @chat_id = chat_id
      @state = data[:state] || State::DEFAULT
      @departments = data[:departments]
      @groups = data[:groups]
      @department_name_temp = data[:department_name_temp]
      @department_url = data[:department_url]
    end

    def default?
      state == State::DEFAULT
    end

    def selecting_department?
      [State::SELECTING_DEPARTMENT, State::SELECTING_DEPARTMENT_QUICK].include? state
    end

    def selecting_group?
      [State::SELECTING_GROUP, State::SELECTING_GROUP_QUICK].include? state
    end

    def selecting_quick?
      [State::SELECTING_DEPARTMENT_QUICK, State::SELECTING_GROUP_QUICK].include? state
    end

    def quick_schedule?
      state == State::SELECTING_QUICK_SCHEDULE
    end

    def selecting_teacher?
      state == State::SELECTING_TEACHER
    end

    def settings?
      state == State::SETTINGS
    end

    def setting_daily_sending?
      state == State::SETTING_DAILY_SENDING
    end

    def private?
      id.to_s.to_i.positive?
    end

    def supergroup?
      id.to_s.to_i.negative?
    end

    def zaochnoe?
      @department_name.downcase =~ /заочн/
    end

    def cache_key
      :"chat_#{chat_id}"
    end

    def save
      Cache.set cache_key, self
    end

    def to_h
      { state: state, departments: departments, groups: groups, department_name_temp: department_name_temp,
        department_url: department_url }
    end
  end
end
