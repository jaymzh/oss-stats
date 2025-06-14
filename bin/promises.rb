#!/usr/bin/env ruby

require 'sqlite3'
require 'optparse'
require 'date'

require_relative '../lib/oss_stats/log'
require_relative '../lib/oss_stats/config/promises'

log.level = :info

def initialize_db(path)
  db = SQLite3::Database.new(path)
  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS promises (
      id INTEGER PRIMARY KEY,
      description TEXT NOT NULL,
      promised_on DATE NOT NULL,
      resolved_on DATE,
      reference TEXT,
      status TEXT DEFAULT 'pending'
    );
  SQL
  db.close
end

def parse_date(str)
  Date.parse(str)
rescue ArgumentError
  puts "Invalid date: #{str}"
  exit 1
end

def add_promise(config, desc, date, ref)
  db = SQLite3::Database.new(config.db_file)
  db.execute(
    "INSERT INTO promises (description, promised_on, reference)
     VALUES (?, ?, ?)",
    [desc, date.to_s, ref],
  )
  db.close
  puts 'Promise added.'
end

def resolve_promise(config, date)
  update_promise_status(config, date, 'resolved')
end

def abandon_promise(config, date)
  update_promise_status(config, date, 'abandoned')
end

def update_promise_status(config, date, new_status)
  db = SQLite3::Database.new(config.db_file)
  rows = db.execute(
    "SELECT id, description FROM promises WHERE status = 'pending'",
  )
  if rows.empty?
    puts 'No pending promises.'
    db.close
    return
  end

  puts 'Pending promises:'
  rows.each_with_index do |(id, desc), _i|
    puts "#{id}. #{desc}"
  end

  print 'Enter ID to update: '
  chosen_id = gets.strip.to_i
  if rows.any? { |r| r[0] == chosen_id }
    if new_status == 'resolved'
      db.execute(
        "UPDATE promises SET resolved_on = ?, status = 'resolved' " +
        'WHERE id = ?',
        [date.to_s, chosen_id],
      )
    elsif new_status == 'abandoned'
      db.execute(
        "UPDATE promises SET resolved_on = ?, status = 'abandoned' " +
        'WHERE id = ?',
        [date.to_s, chosen_id],
      )
    end
    puts "Promise marked as #{new_status}."
  else
    puts 'Invalid ID.'
  end
  db.close
end

def edit_promise(config)
  db = SQLite3::Database.new(config.db_file)
  rows = db.execute(
    'SELECT id, description, promised_on, reference FROM promises',
  )
  if rows.empty?
    puts 'No promises available.'
    db.close
    return
  end

  puts 'All promises:'
  rows.each_with_index do |(id, desc, date, ref), i|
    puts "#{i + 1}. #{desc} (ID: #{id}, Date: #{date}, Ref: #{ref})"
  end

  print 'Enter ID to edit: '
  chosen_id = gets.strip.to_i
  entry = rows.find { |r| r[0] == chosen_id }

  unless entry
    puts 'Invalid ID.'
    db.close
    return
  end

  print "New description [#{entry[1]}]: "
  new_desc = gets.strip
  new_desc = entry[1] if new_desc.empty?

  print "New date (YYYY-MM-DD) [#{entry[2]}]: "
  new_date = gets.strip
  new_date = entry[2] if new_date.empty?
  new_date = parse_date(new_date)

  print "New reference [#{entry[3]}]: "
  new_ref = gets.strip
  new_ref = entry[3] if new_ref.empty?

  db.execute(
    "UPDATE promises
     SET description = ?, promised_on = ?, reference = ?
     WHERE id = ?",
    [new_desc, new_date.to_s, new_ref, chosen_id],
  )
  puts 'Promise updated.'
  db.close
end

def output(fh, msg)
  if fh
    fh.write("#{msg}\n")
  else
    log.info(msg)
  end
end

def show_status(config, include_abandoned: false)
  db = SQLite3::Database.new(config.db_file)
  query = "SELECT description, promised_on, reference, status
           FROM promises WHERE status = 'pending'"
  if include_abandoned
    query += " OR status = 'abandoned'"
  end
  rows = db.execute(query)
  db.close

  fh = nil
  if config.output
    fh = open(config.output, 'w')
    log.info("Generating report and writing to #{config.output}")
  end

  output(fh, config.header)

  if rows.empty?
    output(fh, 'No matching promises.')
    return
  end

  today = Date.today
  rows.each do |desc, promised_on, ref, status|
    days = (today - Date.parse(promised_on)).to_i
    label = "#{desc} (#{days} days ago)"
    label += " [ref: #{ref}]" unless ref.empty?
    label += " [#{status}]" if status == 'abandoned'
    output(fh, "* #{label}")
  end
end

def prompt_date(txt = 'Date')
  parse_date(prompt(txt, Date.today.to_s))
end

def prompt(txt, default = nil)
  p = txt
  if default
    p << " [#{default}]"
  end
  print "#{p}: "
  resp = gets.strip
  if resp.empty? && default
    return default
  end
  resp
end

def main
  if ARGV.empty? || %w{--help -h}.include?(ARGV[0])
    puts <<~HELP
      Usage: #{$PROGRAM_NAME} [subcommand] [options]

      Subcommands:
        add-promise         Add a new promise
        resolve-promise     Resolve a pending promise
        abandon-promise     Mark a promise as abandoned
        edit-promise        Edit an existing promise
        status              Show unresolved promises

      Options:
        --date=YYYY-MM-DD         Date of action
        --promise="text"          Promise description
        --reference="text"        Optional reference
        --db-file=FILE            SQLite3 DB file
        --include-abandoned       Show abandoned in status

      Example:
        #{$PROGRAM_NAME} add-promise --promise="Call mom" --date=2025-05-08
    HELP
    exit
  end

  options = {}
  OptionParser.new do |opts|
    opts.on('--date=DATE', 'Date (YYYY-MM-DD)') do |d|
      options[:date] = parse_date(d)
    end

    opts.on('--promise=TEXT', 'Promise text') do |p|
      options[:promise] = p
    end

    opts.on('--reference=TEXT', 'Optional reference') do |r|
      options[:reference] = r
    end

    opts.on(
      '-l LEVEL',
      '--log-level LEVEL',
      'Set logging level to LEVEL. [default: info]',
    ) do |level|
      options[:log_level] = level.to_sym
    end

    opts.on('--db-file=FILE', 'Path to DB file') do |f|
      options[:db_file] = f
    end

    opts.on('--include-abandoned', 'Include abandoned in status') do
      options[:include_abandoned] = true
    end

    opts.on(
      '-o FILE',
      '--output FILE',
      'Write the output to FILE',
    ) { |v| options[:output] = v }

    opts.on('-m MODE', '--mode MODE',
            %w{add resolve abandon edit status},
            'Mode to operate in') do |m|
      options[:mode] = m
    end

    opts.on('-h', '--help', 'Show help') do
      puts opts
      exit
    end
  end.parse!
  log.level = options[:log_level] if options[:log_level]
  config = OssStats::Config::Promises

  if options[:config]
    expanded_config = File.expand_path(options[:config])
  else
    f = config.config_file
    expanded_config = File.expand_path(f) if f
  end

  if expanded_config && File.exist?(expanded_config)
    log.debug("Loading config from #{expanded_config}")
    config.from_file(expanded_config)
  end
  config.merge!(options)
  log.level = config.log_level

  initialize_db(config.db_file)

  case config.mode
  when 'add'
    desc = options[:promise] || prompt('Promise')
    date = options[:date] || promt_date
    ref = options[:reference] || prompt('Reference (optional)')
    add_promise(config, desc, date, ref)
  when 'resolve'
    date = options[:date] || prompt_date('Resolution date')
    resolve_promise(config, date)
  when 'abandon'
    date = options[:date] || prompt_date('Resolution date')
    abandon_promise(config, date)
  when 'edit'
    edit_promise(config)
  when 'status'
    show_status(config, include_abandoned: options[:include_abandoned])
  else
    puts "Unknown mode: #{config.mode}"
    exit 1
  end
end

main if __FILE__ == $PROGRAM_NAME
