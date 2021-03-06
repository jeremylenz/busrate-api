# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# Note that this schema.rb definition is the authoritative source for your
# database schema. If you need to create the application database on another
# system, you should be using db:schema:load, not running all the migrations
# from scratch. The latter is a flawed and unsustainable approach (the more migrations
# you'll amass, the slower it'll run and the greater likelihood for issues).
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema.define(version: 2019_02_17_222206) do

  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "bus_lines", force: :cascade do |t|
    t.string "line_ref"
    t.json "response"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "stop_refs_response"
  end

  create_table "bus_stops", force: :cascade do |t|
    t.string "stop_ref"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "historical_departures", force: :cascade do |t|
    t.string "stop_ref", null: false
    t.string "line_ref", null: false
    t.datetime "departure_time"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "vehicle_ref"
    t.bigint "bus_stop_id"
    t.bigint "headway"
    t.bigint "previous_departure_id"
    t.string "block_ref"
    t.string "dated_vehicle_journey_ref"
    t.boolean "interpolated"
    t.integer "direction_ref"
    t.index ["departure_time"], name: "by_departure_time", order: :desc
    t.index ["stop_ref", "line_ref"], name: "by_stop_line_ref"
  end

  create_table "mta_api_call_records", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "mta_bus_line_lists", force: :cascade do |t|
    t.json "response"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "vehicle_positions", force: :cascade do |t|
    t.bigint "vehicle_id"
    t.bigint "bus_line_id"
    t.string "vehicle_ref"
    t.string "line_ref"
    t.string "arrival_text"
    t.string "feet_from_stop"
    t.string "stop_ref"
    t.datetime "timestamp"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "bus_stop_id"
    t.string "dated_vehicle_journey_ref"
    t.string "block_ref"
    t.integer "direction_ref"
    t.index ["bus_line_id"], name: "index_vehicle_positions_on_bus_line_id"
    t.index ["vehicle_id"], name: "index_vehicle_positions_on_vehicle_id"
  end

  create_table "vehicles", force: :cascade do |t|
    t.string "vehicle_ref"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

end
