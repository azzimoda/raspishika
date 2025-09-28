# frozen_string_literal: true

require_relative 'database_test_helper'
describe Raspishika::Chat do
  let(:old_chat_data) { { tg_id: '1', username: 'old_username' } }
  let(:updated_old_chat_data) { { tg_id: '1', username: 'new_username' } }
  let(:new_chat_data) { { tg_id: '2', username: 'old_username' } }

  before do
    Raspishika::Chat.create(**old_chat_data)
    pp Raspishika::Chat.all.to_a
  end

  after do
    Raspishika::Chat.all.destroy_all
  end

  it 'must update username of old chat and create new chat' do
    chat = Raspishika::Chat.find_by tg_id: new_chat_data[:tg_id]
    _(chat).must_be_nil

    unless chat
      # Try to create new chat
      chat = Raspishika::Chat.create(**new_chat_data)
      _(chat.persisted?).must_equal false

      unless chat.persisted?
        # Chat was not created
        # Try to update old chat's username
        chat0 = Raspishika::Chat.find_by username: new_chat_data[:username]
        _(chat0.nil?).must_equal false

        if chat0 && chat0.username != updated_old_chat_data[:username]
          chat0.update username: updated_old_chat_data[:username]
          chat = Raspishika::Chat.create(**new_chat_data)
          _(chat.persisted?).must_equal true
        end
      end
    end

    pp Raspishika::Chat.all.to_a
    _(Raspishika::Chat.all.count).must_equal 2
  end
end
