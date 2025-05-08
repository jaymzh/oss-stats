db_file DEFAULT_DB_FILE = File.expand_path(
  './data/promises.sqlite3',
  __dir__,
)
header <<~EOF
    # Promises Report #{Date.today.to_s}
EOF
