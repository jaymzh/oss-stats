# Promises

[promises](../bin/promises.rb) allows you to add, edit, resolve, abandon, and
report on promises made. This can be useful for both promises made to the
community or promises made between teams.

You likely will probably want a config file for this; a sample
is provided in [../examples/promises_config.rb](../examples/promises_config.rb).

There are several sub-commands, discussed below.

## Subcommands

### add-promise

This subcommand allows you to add a new promise. By default the data will be
assumed to be today, but it may be changed with `--date`. You will be prompted
for the promise, but you can specify it with `--promise`.

Promises have 3 pieces of data associated with them:

* `promise` - what was actually promised
* `date` - the date on which it was promised
* `reference` - additional reference about this promise. This could be
  a link to the message, post, notes, etc. in which the promise was made,
  for example. It is arbitrary text and may be whatever you wish.

### resolve-promise

Mark a promise as resolved. It will no longer be reported on by default, and
the date it was resolved will be recorded in the database.

### abandon-promise

This marks a promise as abandoned and is useful in the case of a promise that
is either no longer relevant or is not expected to be resolved.

### edit-promise

If you want to alter information about a promise in the database, this will
re-prompt you for the information and update the database accordingly.

### status

This will output information about the promises in a Slack-friendly Markdown
format. It will list all open promises and how long they've been open. Example
output is:

```markdown
# Promises Report 2025-06-14

* Publish Chef 19 / 2025 plan (247 days ago)
* Fedora 41+ support (227 days ago)
```

You can include abandoned promises with `--include-abandoned`.
