module ImageGenerator
  IMAGE_WIDTH = 1200
  IMAGE_HEIGHT = 800
  CACHE_DIR = File.expand_path('../data/cache', __dir__).freeze
  FileUtils.mkdir_p CACHE_DIR

  @logger = nil

  class << self
    attr_accessor :logger
  end

  def self.generate(page, schedule, sid:, gr:, group:, **)
    logger&.info "Generating image for #{sid} #{gr} #{group}"

    html = generate_html(schedule, group)
    file_path = File.expand_path("table_template.html", CACHE_DIR)
    File.write(file_path, html)

    page.set_viewport_size(width: IMAGE_WIDTH, height: IMAGE_HEIGHT)
    page.goto "file://#{File.absolute_path(file_path)}"
    sleep 1

    output_path = File.expand_path("#{sid}_#{gr}.png", CACHE_DIR)
    page.screenshot(path: output_path)

    logger&.info "Screenshot saved to #{output_path}"
  end

  private

  def self.generate_html(schedule, group)
    <<~HTML
    <!DOCTYPE html>
    <html>
    <head>
      <style>
        body { font-family: Arial, sans-serif; font-size: 10px; margin: 20px; }
        table#main_table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: center; }
        th { background-color: #f2f2f2; }
        .event { background-color: #f9f9f9; }
        .replaced { background-color: #ffcccc; }
        .discipline, .classroom { font-weight: bold; }
      </style>
    </head>
    <body>
      <h2>Расписание группы #{group}</h2>
      <table id='main_table'>
        <thead>
          <tr>
            <th>№</th>
            <th>Время</th>
            #{schedule.first[:days].map { |d|
              "<th>#{d[:date]}<br>#{d[:weekday]}<br>#{d[:week_type]}</th>"
            }.join"\n"}
          </tr>
        </thead>
        <tbody>
          #{generate_table_body schedule}
        </tbody>
      </table>
      <p>Сгенерировано в #{Time.now}</p>
    </body>
    </html>
    HTML
  end

  def self.generate_table_body schedule
    schedule.map do |row|
      <<~HTML
      <tr>
        <td><b>#{row[:pair_number]}</b></td>
        <td><b>#{row[:time_range]}</b></td>
        #{generate_row row}
      </tr>
      HTML
    end.join"\n"
  end

  def self.generate_row row
    row[:days].map do |day|
      css_class = "#{day[:replaced] ? ' replaced' : ''} #{day[:type].to_s}"
      case day[:type]
      when :subject
        <<~HTML
        <td class='#{css_class}'>
          <span class='discipline'>#{day[:subject][:discipline]}</span><br>
          <span class='teacher'>#{day[:subject][:teacher]}</span><br>
          <span class='classroom'>#{day[:subject][:classroom]}</span><br>
        </td>
        HTML
      when :event
        "<td class='#{css_class}'> <span>#{day[:event]}</span><br> </td>"
      when :empty
        "<td class='#{css_class}'> <span>#{day[:replaced] ? 'Снято' : ''}</span><br> </td>"
      end
    end.join"\n"
  end
end
