## Intro

Welcome to BusRate API!  This is the backend for BusRate NYC, an app designed to help provide insights about __bus performance__ in the New York City MTA bus system.

## How it works

1. Every 30 seconds, BusRate API calls the [MTA BusTime API](http://bustime.mta.info/wiki/Developers/SIRIVehicleMonitoring) and gets the locations of every vehicle in the system.  For each vehicle, this data includes a stop reference (which bus stop) and an arrival text ("approaching", "at stop", "< 1 stop away", etc.)
2. The vehicle locations are persisted to the database.
3. Every minute, the BusRate API compares all of the _vehicle locations_ less than 4 minutes old.
4. If two vehicle locations meet the criteria for a departure, a historical departure is recorded in the BusRate API database.  (For the specific rules, see the comments in the `is_departure?` method in `app/models/historical_departure.rb`)
5. Approximately 800 historical departures are created every minute.

## Live demo

If you don't want to follow the manual instructions below, check out the front-end repo at https://github.com/jeremylenz/busrate.  In the `constants.js` file of that repo, you'll find the static IP of the demo API server.  You can feel free to use Postman or Insomnia to make requests to the API endpoints.

## Getting started

### 1. Install the Rails app

After cloning the repo, run `bundle install` and confirm that it completes successfully.

### 2. Get an API key and save it

Next, you'll need an API key from the MTA.  You can request one from [here](http://bustime.mta.info/wiki/Developers/Index)

This app uses the Rails Credentials feature to store secrets.  Once you have your API key, run the following command in Terminal:

`EDITOR="atom --wait" rails credentials:edit`

(This assumes your text editor is Atom.  If you use a different editor, change the EDITOR variable accordingly.  If you leave it off, Rails will use your default text editor but it may not work without the wait flag.)

Add the API key as follows:

```
mta:
  api_key: [YOUR_API_KEY_HERE]
```

Now save the file and close your editor.

### 3. Run the app for the first time

At a terminal, run
```
rails db:create
rails db:migrate
rails server
```

If you're also running the React front-end locally, instead of `rails server` you may want to instead run `rails server -p 5000` to run the server on port 5000 so as not to conflict.

Send a request to `[API_URL]/api/v1/mta/routes`.  This calls the BusTime API and retrieves descriptions of all the bus lines for New York City Transit as well as MTA Bus, and combines them into one list.  It also saves them in the BusRate API database.  __IMPORTANT:__ This must be done at least once before the rest of the app will work properly.  If there are no bus lines in the system, no vehicle positions will be extracted from the BusTime API response.

### 4. Get MTA vehicle data

In the terminal, run `rails console` and then type `HistoricalDeparture.grab_all`.  After the API call is complete, `VehiclePosition.all.count` should be nonzero.  This will confirm that the app is working and calling the MTA BusTime API properly.

### 5. Set up the Whenever gem

This app uses the Whenever gem to set up cron jobs to retrieve MTA BusTime data regularly.

1. Copy (don't rename) `schedule.example.rb` to a new file.  Name the file `schedule.rb`.
2. Edit the `schedule.rb` file depending on your environment.  For a development environment, no changes should be needed.  For a Production environment, you may need to make the following changes:

```
set :output, 'path_to_cron_jobs_log_file'
set :environment, 'production'
set :bundle_command, '/usr/local/bin/bundle exec' # For some reason it couldn't find my bundler, so you may need to experiment with this
env :BUSRATE_API_DATABASE_PASSWORD, ENV['BUSRATE_API_DATABASE_PASSWORD']
```

In addition, for a Production environment, you will need to create a `busrate-api` Postgres user and specify a password.  You will also need to set the `BUSRATE_API_DATABASE_PASSWORD` environment variable to the password that you set.

3. In a Terminal, run the following command:
```
whenever --update-crontab
```

You will see your schedule, followed by the following message:
```
## [message] Above is your schedule file converted to cron syntax; your crontab file was not updated.
## [message] Run `whenever --help' for more options.
```

As long as the message above is NOT the only output, this will confirm that the cron job schedule has started running.

4. To stop running the cron jobs, comment out everything in `schedule.rb` and run `whenever --update-crontab`.

Please note: The output of the tasks logs to the cron jobs log file _only_ when there is a problem.  When everything is running properly, logs will show up in `development.log` or `production.log`.

### 6. Make requests

The API only supports GET requests (no POST, PATCH, DELETE, etc.) Send HTTP GET requests to the following endpoints:

#### BusRate API endpoints

* `/api/v1/stats` - List of statistics describing the data we've collected so far.  Example:
```
{
  "mta_api_all_vehicles_calls": 9,
  "historical_departures": "15,057,966",
  "historical_departures_last_300_seconds": 5198,
  "vehicle_positions": 50017,
  "vehicle_positions_last_300_seconds": 21868,
  "bus_lines": 332,
  "bus_stops": 15501,
  "vehicles": 5577,
  "avg_vehicle_positions_per_api_call": 2429,
  "avg_departures_per_api_call": 577,
  "response_timestamp": "2018-12-03T18:21:21.882-05:00"
}
```
* `/api/v1/bus_stops/:bus_stop_id/historical_departures?lineRef=[LINE_REF_HERE]` - Returns the last 8 historical departures for the lineRef and stopRef specified.

#### MTA BusTime pass-through endpoints
The following endpoints call the MTA BusTime API:

* `api/v1/stoplists/:id`
* `/api/v1/mta/vehicles_for_stop/:id`
* `/api/v1/mta/vehicles_for_route/:id`
