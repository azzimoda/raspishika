# frozen_string_literal: true

require_relative 'test_helper'

describe 'user-agent-randomizer' do
  # 100.times do |i|
  #   it "should not repeat ##{i + 1}" do
  #     100.times.with_object(Set[]) do |_, list|
  #       user_agent = UserAgentRandomizer::UserAgent.fetch.string.to_s
  #       _(list.include?(user_agent)).must_equal false
  #       list << user_agent
  #     end
  #   end
  # end

  let(:bot) { initialize_bot }

  10.times do |i|
    groups_set.each do |group_info|
      it "must successfully fetch schedule ##{i + 1} for group #{group_info}" do
        _(bot.parser.fetch_schedule(group_info)).wont_be_nil
      end
    end
  end
end
