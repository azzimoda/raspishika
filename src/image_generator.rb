module ImageGenerator
  IMAGE_WIDTH = 1200
  IMAGE_HEIGHT = 800
  CACHE_DIR = File.expand_path('../data/cache', __dir__).freeze
  FileUtils.mkdir_p CACHE_DIR

  @logger = nil

  class << self
    attr_accessor :logger
  end

  def self.generate(page, schedule, **group_info)
    logger&.info "Generating image for #{group_info}"

    html = generate_html(schedule, group_info[:group], group_info[:department])
    file_path = File.expand_path("table_template.html", CACHE_DIR)
    File.write(file_path, html)

    page.set_viewport_size(width: IMAGE_WIDTH, height: IMAGE_HEIGHT)
    page.goto "file://#{File.absolute_path(file_path)}"
    sleep 1

    output_path = image_path(**group_info)
    page.screenshot(path: output_path)

    logger&.debug "Screenshot saved to #{output_path}"
  end

  def self.image_path(sid:, gr:, group:, department:, **)
    File.expand_path("#{sid}_#{gr}_#{department}_#{group}.png", CACHE_DIR)
  end

  private

  def self.generate_html(schedule, group, department)
    <<~HTML
    <!DOCTYPE html>
    <html>
    <head>
      <style>
        body { font-family: Arial, sans-serif; font-size: 10px; margin: 20px; }
        table#main_table { border-collapse: collapse; table-layout: fixed; width: 100%; }
        th, td { border: 1px solid gray; padding: 4px; text-align: center; }
        th, td.side_column_number, td.side_column_time { background-color: #f2f2f2; }
        .side_column_number { width: 1%; }
        .side_column_time { width: 3%; }
        .replaced { background-color: #fae4d7; }
        .discipline, .classroom { font-weight: bold; }
        .event { background-color: #fa8072; }
        .iga { background-color: #cfffd9 }
        .practice { background-color: #c0d5fa; }
        .example { border: 1px solid gray; padding: 2px 4px;}
      </style>
    </head>
    <body>
      <h2>Расписание группы #{group} — #{department}</h2>
      <table id='main_table'>
        <thead>
          <tr>
            <th class="side_column_number">№</th>
            <th class="side_column_time">Время</th>
            #{schedule.first[:days].map { |d|
              "<th>#{d[:date]}<br>#{d[:weekday]}<br>#{d[:week_type]}</th>"
            }.join"\n"}
          </tr>
        </thead>
        <tbody>
          #{generate_table_body schedule}
        </tbody>
      </table>
      <p>
        <b>Условные обозначения:</b>
        <span class='example replaced'>замена</span>;
        <!-- <span class='example session'>сессия</span>; -->
        <span class='example event'>праздничный день</span>;
        <span class='example practice'>практика</span>;
        <span class='example iga'>ИГА</span>;
        <!-- <span class='example holiday'>каникулы</span>; -->
      </p>
      <p>Сгенерировано в #{Time.now}</p>
    </body>
    </html>
    HTML
  end

  def self.generate_table_body schedule
    schedule.map do |row|
      <<~HTML
      <tr>
        <td class="side_column_number"><b>#{row[:pair_number]}</b></td>
        <td class="side_column_time">#{row[:time_range].gsub('-', '<hr>')}</td>
        #{generate_row row}
      </tr>
      HTML
    end.join"\n"
  end

  def self.generate_row row
    row[:days].map do |day|
      css_class = "#{day[:replaced] ? ' replaced' : ''} #{day[:type].to_s}"
      case day[:type]
      when :event, :iga, :practice
        "<td class='#{css_class}'><span>#{day[:content]}</span><br></td>"
      when :subject
        <<~HTML
        <td class='#{css_class}'>
        <span class='discipline'>#{day[:content][:discipline]}</span><br>
        <br>
        <span class='teacher'>#{day[:content][:teacher]}</span><br>
        <span class='classroom'>#{day[:content][:classroom]}</span><br>
        </td>
        HTML
      else # when :empty
        "<td class='#{css_class}'><span>#{day[:replaced] ? 'Снято' : ''}</span><br></td>"
      end
    end.join"\n"
  end
end
