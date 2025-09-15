# frozen_string_literal: true

class String # rubocop:disable Style/Documentation
  def escape_markdown
    ['\\', '*', '_', '{', '}', '[', ']', '(', ')', '>', '#', '+', '-', '.', '!', '~']
      .each_with_object(dup) { |c, s| s.gsub! c, "\\#{c}" }
  end
end

class Telegram::Bot::Types::User # rubocop:disable Style/ClassAndModuleChildren,Style/Documentation
  def full_name
    "#{first_name} #{last_name}".strip
  end
end
