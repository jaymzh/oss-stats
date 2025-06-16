# Rolling a release

## Optionally, update Gemfile.lock

* Update gems with `bundle update --all`
* Test to make sure we work with all new deps

## Prep the release

* Update version number in `lib/oss_status/version.rb`
* Update the `CHANGELOG.md`
* Create a PR, get it merged

## Tag the release

* version='0.0.X'
* Add a tag: `git tag -a v${version?} -m "version ${version?}" -s`
* Push the tag: `git push origin --tags`

## Publish a gem

* Build a gem: `gem build oss-stats.gemspec`
* Push the gem: `gem push oss-stats-${version?}.gem`

## Publish GH Release

Go to release, add new one.
