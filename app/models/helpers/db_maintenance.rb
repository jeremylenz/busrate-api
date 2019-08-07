module DBMaintenance
  def self.logger
    Rails.logger
  end

  def self.vacuum_full(wait = 120)
    start_time = Time.current
    self.shut_down_cron_jobs(wait)
    logger.info "Starting VACUUM FULL; ..."
    ActiveRecord::Base.connection.execute("VACUUM FULL;")
  rescue => err
    logger.error err
    false
  ensure
    self.resume_cron_jobs
    logger.info "VACUUM FULL complete in #{(Time.current - start_time).round(2)} seconds"
  end

  def self.do_test
    logger.info "start"
    sql = <<~HEREDOC
      SELECT stats.relname
           AS table,
       pg_size_pretty(pg_relation_size(statsio.relid))
           AS table_size,
       pg_size_pretty(pg_total_relation_size(statsio.relid)
           - pg_relation_size(statsio.relid))
           AS related_objects_size,
       pg_size_pretty(pg_total_relation_size(statsio.relid))
           AS total_table_size,
       stats.n_live_tup
           AS live_rows
      FROM pg_catalog.pg_statio_user_tables AS statsio
      JOIN pg_stat_user_tables AS stats
      USING (relname)
      WHERE stats.schemaname = current_schema  -- Replace with any schema name
      UNION ALL
      SELECT 'TOTAL'
               AS table,
           pg_size_pretty(sum(pg_relation_size(statsio.relid)))
               AS table_size,
           pg_size_pretty(sum(pg_total_relation_size(statsio.relid)
               - pg_relation_size(statsio.relid)))
               AS related_objects_size,
           pg_size_pretty(sum(pg_total_relation_size(statsio.relid)))
               AS total_table_size,
           sum(stats.n_live_tup)
               AS live_rows
      FROM pg_catalog.pg_statio_user_tables AS statsio
      JOIN pg_stat_user_tables AS stats
      USING (relname)
      WHERE stats.schemaname = current_schema  -- Replace with any schema name
      ORDER BY live_rows ASC;
    HEREDOC
    ActiveRecord::Base.connection.execute(sql)
  end

  def self.vacuum_lite(wait = 120)
    start_time = Time.current
    self.shut_down_nonessential_cron_jobs(wait)
    logger.info "Starting VACUUM ANALYZE; ..."
    ActiveRecord::Base.connection.execute("VACUUM ANALYZE;")
  rescue => err
    logger.error err
  ensure
    self.resume_cron_jobs
    logger.info "VACUUM ANALYZE complete in #{(Time.current - start_time).round(2)} seconds"
  end

  def self.shut_down_cron_jobs(wait = 120)
    logger.info "Shutting down cron jobs..."
    system "crontab -r" # clear out crontab
    sleep wait
  end

  def self.resume_cron_jobs
    logger.info "Restarting cron jobs..."
    system "crontab -r" # clear out crontab - ensure we're starting clean
    system "/usr/local/bin/whenever --user jeremylenz --update-crontab -f /home/jeremylenz/code/busrate-api/config/schedule.rb > log/production.log"
  end

  def self.shut_down_nonessential_cron_jobs(wait = 120)
    logger.info "Shutting down nonessential cron jobs..."
    system "crontab -r" # Clear out the crontab
    # Below command will ADD cron jobs in schedule_minimal.rb to the crontab.  So we must ensure crontab is blank when we do this.
    system "/usr/local/bin/whenever --user jeremylenz --update-crontab -f /home/jeremylenz/code/busrate-api/config/schedule_minimal.rb > log/production.log"
    sleep wait
  end

  def self.create_old_departures_temp_table(age_in_weeks = 6)
    sql = <<~HEREDOC
      CREATE TABLE old_hds_temp AS
        SELECT * FROM "historical_departures" WHERE (created_at < '#{age_in_weeks.weeks.ago}');
    HEREDOC
    logger.info ActiveRecord::Base.connection.execute(sql)
  end

  def self.dump_old_departures_to_file(filename = "old_hds.dump")
    # Prompts for a password
    dump_command = <<~HEREDOC
      pg_dump -Fc -t old_hds_temp -v > #{filename} --username=busrate-api --dbname=busrate-api_production
    HEREDOC
    system dump_command
  end

  def self.remove_old_departures_temp_table(filename = "old_hds.dump")
    system "rm #{filename}"
    sql = <<~HEREDOC
      DROP TABLE old_hds_temp;
    HEREDOC
    logger.info ActiveRecord::Base.connection.execute(sql)
  end

  def self.remove_old_departures(age_in_weeks = 6)
    sql = <<~HEREDOC
      DELETE FROM historical_departures WHERE (created_at < '#{age_in_weeks.weeks.ago}');
    HEREDOC
    logger.info ActiveRecord::Base.connection.execute(sql)
  end

  def self.rotate_departures(age_in_weeks = 6)
    # Combining the 4 methods above, in the order they need to happen
    start_time = Time.current
    logger.info "Rotating departures ..."
    logger.info "create_old_departures_temp_table"
    create_old_departures_temp_table(age_in_weeks)

    logger.info "dump_old_departures_to_file"
    dump_old_departures_to_file # Prompts for password
    logger.info "Now copy the file to your local machine:"
    filename = "old_hds_#{Time.current.strftime('%m%d%y')}.dump"
    logger.info "scp jeremylenz@142.93.7.189:~/code/busrate-api/old_hds.dump \"/Volumes/Jer Data Archive/#{filename}\""
    logger.info "Then run clean_up_rotate_departures"
    logger.info "Done in #{(Time.current - start_time).round(2)} seconds"

    # -- On local machine:
    # scp jeremylenz@142.93.7.189:~/code/busrate-api/old_hds.dump "/Volumes/Jer Data Archive/old_hds_043019.dump"
  end

  def self.clean_up_rotate_departures(age_in_weeks = 6)
    start_time = Time.current
    logger.info "remove_old_departures"
    remove_old_departures(age_in_weeks)
    logger.info "remove_old_departures_temp_table and rm old_hds.dump"
    remove_old_departures_temp_table
    logger.info "Now you should run sudo logrotate /home/jeremylenz/code/busrate-api/log/logrotate.conf"
    logger.info "Done in #{(Time.current - start_time).round(2)} seconds"
  end

end
