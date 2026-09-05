db_file DEFAULT_DB_FILE = File.expand_path(
  './data/meeting_data.sqlite3',
  __dir__,
)
output File.expand_path('./team_meeting_reports.md', __dir__)
image_dir File.expand_path('./images', __dir__)
# Day of week the meeting is held on. Used to compute the most recent
# meeting date when `--date` is not given. One of: sunday, monday,
# tuesday, wednesday, thursday, friday, saturday.
meeting_dow 'thursday'
# How often the meeting happens. One of: daily, weekly, 2weeks, monthly.
# Used, along with meeting_dow, to walk forward from the last meeting
# recorded in the database up through today when `--date` is not given.
meeting_frequency 'weekly'
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
