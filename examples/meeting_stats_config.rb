db_file DEFAULT_DB_FILE = File.expand_path(
  './data/meeting_data.sqlite3',
  __dir__,
)
output File.expand_path('./team_meeting_reports.md', __dir__)
image_dir File.expand_path('./images', __dir__)
# NOTE: This is an INITIAL list only!
teams [
  'Client',
  'Server',
  'Core Libs',
]
header <<~EOF
    # Slack Meeting tracking

    some stuff here...

    ## Trends

    [![Attendance](images/attendance-small.png)](images/attendance-full.png)
    [![Build Status
       Reports](images/build_status-small.png)](images/build_status-full.png)
EOF
