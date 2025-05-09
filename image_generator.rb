module ImageGenerator
  CACHE_DIR = File.expand_path('.cache', __dir__).freeze

  def self.generate(driver, schedule, sid:, gr:, group:)
    html = generate_html(schedule, group)
    file_path = File.expand_path("table_template.html", CACHE_DIR)
    File.write(file_path, html)

    driver.navigate.to "file://#{File.absolute_path(file_path)}"
    sleep 1
    driver.manage.window.resize_to(1920, 1080)
    driver.save_screenshot(File.expand_path("#{sid}_#{gr}.png", CACHE_DIR))
  end

  private

  def self.generate_html(schedule, group)
    # pp schedule
    <<~HTML
    <!DOCTYPE html>
    <html>
    <head>
      <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: center; }
        th { background-color: #f2f2f2; }
        .weekend { background-color: #f9f9f9; }
      </style>
    </head>
    <body>
      <h2>Расписание группы #{group}</h2>
      <table>
        <thead>
          <tr>
            <th>№</th>
            <th>Время</th>
            #{schedule[0][:days].map { |d|
              "<th>#{d[:date]}<br>#{d[:weekday]}<br>#{d[:week_type]}</th>"
            }.join"\n"}
          </tr>
        </thead>
        <tbody>
          #{schedule.map { |row| 
            "<tr>
              <td>#{row[:pair_number]}</td>
              <td>#{row[:time_range]}</td>
              #{row[:days].map { |day| "<td>#{day[:subject].values.join"<br>"}</td>" }.join}
            </tr>"
          }.join"\n"}
        </tbody>
      </table>
    </body>
    </html>
    HTML
  end
end