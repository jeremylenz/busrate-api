module FastInsert

  extend ActiveSupport::Concern

  included do
    logger.info "including FastInsert for #{self}"
  end

  # Instance methods go here

  # Class methods go here

  module ClassMethods

    def fast_insert_objects(tabl_name, object_list)
      # Use the fast_inserter gem to write hundreds of rows to the table
      # with a single SQL statement.  (Active Record is too slow in this situation.)
      return if object_list.blank?
      fast_inserter_start_time = Time.current
      fast_inserter_variable_columns = object_list.first.keys.map(&:to_s)
      fast_inserter_values = object_list.map { |nvpp| nvpp.values }
      fast_inserter_params = {
        table: tabl_name,
        static_columns: {}, # values that are the same for each record
        options: {
          timestamps: true, # write created_at / updated_at
          group_size: 2_000,
        },
        variable_columns: fast_inserter_variable_columns, # column names of values that are different for each record
        values: fast_inserter_values, # values that are different for each record
      }
      model = tabl_name.classify.constantize # get Rails model class from table name
      last_id = model.order(id: :desc).first&.id || 0

      inserter = FastInserter::Base.new(fast_inserter_params)
      logger.info "Fast-inserting #{tabl_name}"
      inserter.fast_insert
      # logger.info "#{table_name} fast_inserter complete in #{(Time.current - fast_inserter_start_time).round(2)} seconds"
      model_name = tabl_name.classify
      logger.info "#{fast_inserter_values.length} #{model_name}s fast-inserted"
      # Return an ActiveRecord relation with the objects just created
      model.where(['id > ?', last_id])
    end

  end # ClassMethods

end
