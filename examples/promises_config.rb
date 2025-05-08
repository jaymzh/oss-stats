# Example promises config file.
#
# You can specify anything in here you can specify on the command-line
# except for --date, --promise, and --reference.

db_file DEFAULT_DB_FILE = File.expand_path(
  './data/promises.sqlite3',
  __dir__,
)
header <<~EOF
    # Promises Report #{Date.today.to_s}
EOF

# Uncomment this and set it to a string to have the output
# of this script written to a file.
#
# output nil

# Uncomment to change the default log level
# log_level :info

# Uncomment to include promises marked 'abandoned' in status output
# include_abandoned false
