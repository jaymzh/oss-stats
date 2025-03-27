#!/usr/bin/env ruby

require 'optparse'
require 'date'
require 'sqlite3'
require 'fileutils'
require 'gruff'

require_relative 'utils/log'

DB_FILE = File.expand_path('../data/meeting_data.sqlite3', __dir__)
SLACK_MD_FILE = File.expand_path('../team_slack_reports.md', __dir__)
IMG_DIR = File.expand_path('../images', __dir__)

# Initialize database
def initialize_db
  db = SQLite3::Database.new(DB_FILE)
  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS meeting_stats (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      meeting_date TEXT,
      team TEXT,
      present TEXT,
      current_work TEXT,
      build_status TEXT,
      fix_points TEXT,
      extra TEXT,
      UNIQUE(meeting_date, team) -- Ensure unique constraint on meeting_date and team
    );
      team TEXT,
      present TEXT,
      current_work TEXT,
      build_status TEXT,
      fix_points TEXT,
      extra TEXT
    );
  SQL
  db.close
end

# Get last Thursday from a given date (or today)
def get_last_thursday(target_date = Date.today)
  target_date -= 1 while target_date.wday != 4 # 4 = Thursday
  target_date
end

# Prompt user for a Yes/No response
def prompt_yes_no(question)
  loop do
    print "#{question} (y/N): "
    response = gets.strip.downcase
    return response == 'y' if ['y', 'n', ''].include?(response)

    log.info("Please enter 'y' or 'n'.")
  end
end

def prompt_team_or_q(teams)
  # it's length, not length-1 because we add one for <other>
  max_num = teams.length
  loop do
    log.info("Choose a team that was present:\n")
    (teams + ['<Other>']).each_with_index do |team, idx|
      log.info("\t[#{idx}] #{team}\n")
    end
    log.info("\t[q] <quit>")
    response = gets.strip.downcase
    return false if response == 'q'
    begin
      i = Integer(response)
      if i < max_num
        return teams[i]
      end

      if i == max_num
        print 'Team name: '
        response = gets.strip
        return response
      end

      log.error("Invalid response: #{response}")
    rescue ArgumentError
      log.error("Invalid response: #{response}")
    end
  end
end

# Collect team data from user
def collect_team_data(meeting_date)
  teams = [
    'Chef Client',
    'Chef Server',
    'Chef Workstation',
    'Automate',
    'Habitat',
    'Courier',
    'Inspec',
  ]
  team_data = {}

  log.info("Please fill in data about the #{meeting_date} meeting\n")
  loop do
    team = prompt_team_or_q(teams)
    unless team
      missing_teams = teams - team_data.keys
      log.info(
        'The following teams will be recorded as not present: ' +
           missing_teams.join(', '),
      )
      if prompt_yes_no('Is that correct?')
        missing_teams.each do |mt|
          team_data[mt] = {
            'present' => false,
            'current_work' => false,
            'build_status' => '',
            'fix_pointers' => '-',
            'extra' => '-',
          }
        end
        break
      else
        next
      end
    end

    if team_data[team]
      if prompt_yes_no("WARNING: #{team} data already input - overwrite?")
        log.info("OK, overwriting data for #{team} on #{meeting_date}")
      else
        next
      end
    end

    log.info("\nTeam: #{team}")
    team_data[team] = {}
    team_data[team]['present'] = true
    team_data[team]['current_work'] = prompt_yes_no(
      'Did they discuss current work?',
    )
    print "Enter build status (e.g. green, red, or 'main:green, 18:red'): "
    build_status = gets.strip
    team_data[team]['build_status'] = build_status
    fix_pointers = if build_status.include?('red')
                     if prompt_yes_no(
                       'Did they point to work to fix the build?',
                     )
                       'Y'
                     else
                       'N'
                     end
                   else
                     '-'
                   end
    team_data[team]['fix_pointers'] = fix_pointers
    extra = []
    merged_prs = prompt_yes_no('Did they list merged PRs that week?')
    extra << 'listed merged PRs' if merged_prs
    print 'Any extra notes? (leave empty if none): '
    extra_notes = gets.strip
    extra << extra_notes unless extra_notes.empty?
    team_data[team]['extra'] = if extra.empty?
                                 '-'
                               else
                                 extra.join(', ')
                               end
  end
  team_data.map do |team, info|
    [
      team,
      info['present'] ? 'Y' : 'N',
      info['current_work'] ? 'Y' : 'N',
      info['build_status'],
      info['fix_points'],
      info['extra'],
    ]
  end
end

# Insert meeting data into the database
def record_meeting_data(meeting_date, team_data, options)
  if options[:dryrun]
    log.info('DRYRUN: Would record the following rows:')
    team_data.each do |row|
      log.info(row.join(', '))
    end
    return
  end

  db = SQLite3::Database.new(DB_FILE)
  team_data.each do |row|
    db.execute(
      'INSERT INTO meeting_stats (meeting_date, team, present, current_work,' +
      'build_status, fix_points, extra) VALUES (?, ?, ?, ?, ?, ?, ?)' +
      ' ON CONFLICT(meeting_date, team) DO UPDATE' +
      ' SET present=excluded.present, current_work=excluded.current_work,' +
      ' build_status=excluded.build_status, fix_points=excluded.fix_points,' +
      ' extra=excluded.extra',
      [meeting_date.to_s] + row,
    )
  end
  db.close
  log.info("Data recorded for #{meeting_date}.")
end

# Retrieve meeting data from database
def fetch_meeting_data(meeting_date)
  db = SQLite3::Database.new(DB_FILE)
  results = db.execute(
    'SELECT team, present, current_work, build_status, fix_points, extra' +
    ' FROM meeting_stats WHERE meeting_date = ?',
    [meeting_date.to_s],
  )
  db.close
  results
end

# Format Yes/No to display emojis
def format_yes_no(value)
  return '❌' if !value || value.strip.upcase == 'N'
  return '✅' if value.strip.upcase == 'Y'

  value
end

# Format build status to display emojis correctly
def format_build_status(status)
  return '❌' if status.nil? || status.strip.empty?

  if %w{red green}.include?(status)
    status = "main:#{status}"
  end
  status.gsub('red', '❌').gsub('green', '✅')
end

# Generate Markdown table
def generate_md_page
  db = SQLite3::Database.new(DB_FILE)
  meeting_dates = db.execute(
    'SELECT DISTINCT meeting_date FROM meeting_stats ORDER BY meeting_date' +
    ' DESC',
  ).flatten
  md = [
    '# Slack status tracking',
    '',
    'This document tracks status updates from Progress teams. While other',
    'teams such as Sous Chefs, Cinc, and Meta sometimes post updates, this',
    'document tracks internal teams only',
    '',
    'This page is generated by slack_meeting_stats.rb, do not edit manually',
    '',
    '## Trends',
    '',
    '[![Attendance](images/attendance-small.png)](images/attendance-full.png)',
    '[![Build Status',
    ' Reports](images/build_status-small.png)](images/build_status-full.png)',
    '',
  ]

  meeting_dates.each do |meeting_date|
    team_data = db.execute(
      'SELECT team, present, current_work, build_status, fix_points, extra' +
      ' FROM meeting_stats WHERE meeting_date = ?',
      [meeting_date],
    )
    md << "## #{meeting_date}"
    md << ''
    md << '| Team | Present | Current work | Build Status |' +
          ' If builds broken, points to work to fix it | Extra |'
    md << '| --- | ---- | --- | --- | --- | --- |'
    team_data.each do |row|
      row = row.dup # This makes the row mutable
      row[1] = format_yes_no(row[1])  # Present
      row[2] = format_yes_no(row[2])  # Current work
      row[3] = format_build_status(row[3]) # Build Status
      row[4] = format_yes_no(row[4]) # Fix Points
      md << '| ' + row.join(' | ') + ' |'
    end
    md << ''
  end
  db.close
  md.join("\n")
end

def generate_plots
  db = SQLite3::Database.new(DB_FILE)
  data = db.execute(
    'SELECT meeting_date, team, present, build_status FROM meeting_stats' +
    ' ORDER BY meeting_date ASC',
  )
  db.close

  dates = data.map { |row| row[0] }.uniq
  attendance_percentages = []
  build_status_percentages = []

  dates.each do |date|
    total_teams = data.count { |row| row[0] == date }
    present_teams = data.count { |row| row[0] == date && row[2] == 'Y' }
    reporting_builds = data.count do |row|
      row[0] == date && row[3] != 'N' && !row[3].strip.empty?
    end

    attendance_percentages <<
      (total_teams == 0 ? 0 : (present_teams.to_f / total_teams) * 100)
    build_status_percentages <<
      (total_teams == 0 ? 0 : (reporting_builds.to_f / total_teams) * 100)
  end

  sizes = {
    'full' => [800, 500],
    'small' => [400, 250],
  }

  sizes.each do |name, size|
    g = Gruff::Line.new(size[0], size[1])
    g.maximum_value = 100
    g.minimum_value = 0
    g.title = 'Percentage of Teams Present Over Time'
    g.data('% Teams Present', attendance_percentages)
    g.labels = dates.each_with_index.to_h
    g.write(::File.join(IMG_DIR, "attendance-#{name}.png"))

    g2 = Gruff::Line.new(size[0], size[1])
    g2.maximum_value = 100
    g2.minimum_value = 0
    g2.title = 'Percentage of Teams Reporting Build Status Over Time'
    g2.data('% Reporting Build Status', build_status_percentages)
    g2.labels = dates.each_with_index.to_h
    g2.write(::File.join(IMG_DIR, "build_status-#{name}.png"))
  end
end

# Parse command-line arguments
options = { mode: 'record', dryrun: false, log_level: :info }
OptionParser.new do |opts|
  opts.banner = 'Usage: script.rb [options]'

  opts.on('--date DATE', 'Date of the meeting in YYYY-MM-DD format') do |v|
    options[:date] =
      begin
        Date.parse(v)
      rescue
        nil
      end
  end

  opts.on(
    '-l LEVEL',
    '--log-level LEVEL',
    'Set logging level to LEVEL. [default: info]',
  ) do |level|
    options[:log_level] = level.to_sym
  end

  opts.on(
    '-m MODE',
    '--mode MODE',
    %w{record generate generate_plot},
    'Mode to operate in. record: Input new meeting info, generate: generate ' +
    'both plot and markdown files, generate_plot: generate new plots',
  ) do |v|
    options[:mode] = v
  end

  opts.on('-n', '--dryrun', 'Do not actually make changes') do |_v|
    options[:dryrun] = true
  end
end.parse!
log.level = options[:log_level] if options[:log_level]

initialize_db
meeting_date = options[:date] || get_last_thursday

case options[:mode]
when 'record'
  team_data = collect_team_data(meeting_date)
  record_meeting_data(meeting_date, team_data, options)
when 'generate_md'
  if options[:dryrun]
    log.info('DRYRUN: Would update plots')
    log.info("DRYRUN: Would update #{SLACK_MD_FILE} with:")
    log.info(generate_md_page)
  else
    log.info('Updating plots...')
    generate_plots
    log.info("Generating #{SLACK_MD_FILE}")
    File.write(SLACK_MD_FILE, generate_md_page)
  end
when 'generate_plot'
  if options[:dryrun]
    log.info('DRYRUN: Would update plots')
  else
    generate_plots
    log.info('Plots generated: attendance.png and build_status.png')
  end
else
  log.info('Invalid mode. Use --mode record, markdown, or plot.')
end
