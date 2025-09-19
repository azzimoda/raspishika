# frozen_string_literal: true

require_relative 'config'
require_relative 'logger'

module Raspishika
  module ImageGenerator
    extend GlobalLogger

    TEMPLATE = File.read(File.expand_path('html/template.html', __dir__))
    IMAGE_WIDTH = Config[:image_generator][:width]
    IMAGE_HEIGHT = Config[:image_generator][:height]
    CACHE_DIR = File.expand_path('../data/cache', __dir__).freeze
    FileUtils.mkdir_p CACHE_DIR

    def self.generate(page, schedule, group_info: nil, teacher_id: nil, teacher_name: nil)
      raise ArgumentError, 'Schedule is empty' unless schedule&.any?

      logger.info "Generating image for #{group_info || { teacher_name: teacher_name, teacher_id: teacher_id }}"

      html = generate_html(schedule, group_info, teacher_name)
      file_path = File.expand_path('table_template.html', CACHE_DIR)
      File.write(file_path, html)

      page.set_viewport_size(width: IMAGE_WIDTH, height: IMAGE_HEIGHT)
      page.goto "file://#{File.absolute_path(file_path)}", timeout: ScheduleParser::TIMEOUT * 1000
      sleep 1

      output_path = image_path(group_info: group_info, teacher_id: teacher_id)
      page.screenshot(path: output_path, timeout: ScheduleParser::TIMEOUT * 1000)

      logger.debug "Screenshot saved to #{output_path}"
    end

    def self.image_path(group_info: nil, teacher_id: nil)
      department, group = group_info&.values_at :department, :group
      file_name = teacher_id ? "teacher_#{teacher_id}.png" : "#{department}_#{group}.png"
      File.expand_path file_name, CACHE_DIR
    end

    def self.generate_html(schedule, group_info, teacher_name)
      raise ArgumentError, 'Schedule is empty' unless schedule&.any?

      group, department = group_info&.then { [it[:group], it[:department]] }
      header = "Расписание #{teacher_name ? "преподавателя — #{teacher_name}" : "группы #{group} — #{department}"}"
      head_row = schedule.first[:days].map do |d|
        "<th>#{d[:date]}<br>#{d[:weekday]}<br>#{d[:week_type]}</th>"
      end.join("\n")
      TEMPLATE.sub('HEADER', header).sub('HEAD_ROW', head_row).sub('TABLE_BODY', generate_table_body(schedule))
              .sub('TIMESTAMP', Time.now.to_s)
    end

    def self.generate_table_body(schedule)
      schedule.map do |row|
        <<~HTML
          <tr>
            <td class="side_column_number"><b>#{row[:pair_number]}</b></td>
            <td class="side_column_time">#{row[:time_range].gsub('-', '<hr>')}</td>
            #{generate_row row}
          </tr>
        HTML
      end.join "\n"
    end

    def self.generate_row(row)
      row[:days].map do |day|
        css_class = "#{' replaced' if day[:replaced]} #{day[:type]}"
        case day[:type]
        when :event, :iga, :practice, :session, :vacation
          "<td class='#{css_class}'><span>#{day[:content]}</span><br></td>"
        when :exam, :consultation
          <<~HTML
            <td class='#{css_class}'>
              <span class='title'>#{day[:title]}</span><br>
              <hr>
              <span class='discipline'>#{day.dig :content, :discipline}</span><br> <br>
              <span class='teacher'>#{day.dig :content, :teacher}</span><br>
              <span class='classroom'>#{day.dig :content, :classroom}</span><br>
            </td>
          HTML
        when :subject
          second_line =
            if (group = day.dig :content, :group)
              "<span class='group'>#{group}</span><br>"
            else
              "<span class='teacher'>#{day.dig :content, :teacher}</span><br>"
            end
          <<~HTML
            <td class='#{css_class}'>
              <span class='discipline'>#{day.dig :content, :discipline}</span><br>
              <br>
              #{second_line}
              <span class='classroom'>#{day.dig :content, :classroom}</span><br>
            </td>
          HTML
        else "<td class='#{css_class}'><span>#{'Снято' if day[:replaced]}</span><br></td>"
        end
      end.join "\n"
    end
  end
end
