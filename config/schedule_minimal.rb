# Use this file to easily define all of your cron jobs.
#
# It's helpful, but not entirely necessary to understand cron before proceeding.
# http://en.wikipedia.org/wiki/Cron

# Example:
#
# set :output, "/path/to/my/cron_log.log"
#
# every 2.hours do
#   command "/usr/bin/some_great_command"
#   runner "MyModel.some_method"
#   rake "some:great:rake:task"
# end
#
# every 4.days do
#   runner "AnotherModel.prune_old_records"
# end

# Learn more: http://github.com/javan/whenever

# Duplicate this file and name it schedule.rb.  Then, at a command line, run
# whenever --update-crontab

set :output, '~/code/busrate-api/log/production.log'
set :environment, 'production'
set :bundle_command, '/usr/local/bin/bundle exec'
env :BUSRATE_API_DATABASE_PASSWORD, ENV['BUSRATE_API_DATABASE_PASSWORD']

every 1.minute do
 runner "VehiclePosition.grab_all"
end

every 1.minute do
  runner "VehiclePosition.wait_and_grab(32)"
end

every 1.minute do
  runner "VehiclePosition.wait_and_grab(15)"
end

every 1.minute do
  runner "VehiclePosition.wait_and_grab(45)"
end

every 1.minute do
  runner "HistoricalDeparture.scrape_all"
end

