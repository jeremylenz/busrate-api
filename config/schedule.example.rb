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

set :output, '/Users/jeremylenz/code/personal/busrate-api/log/cron-jobs.log'
set :environment, 'development'

every 8.minutes do
  runner "VehiclePosition.clean_up"
end

every 1.minute do
  runner "HistoricalDeparture.grab_and_go"
end

every 1.minute do
  runner "HistoricalDeparture.scrape_all"
end

every 1.minute do
  runner "HistoricalDeparture.calculate_headways(HistoricalDeparture.newer_than(14_400))"
end

every 29.minutes do
  command "curl localhost:3000/api/v1/ping"
end

every 1.hour do
  runner "HistoricalDeparture.purge_duplicates_newer_than(3700)"
end
