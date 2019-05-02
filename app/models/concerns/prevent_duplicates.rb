module PreventDuplicates

  extend ActiveSupport::Concern

  included do
  end

  module ClassMethods
    def self.prevent_duplicates(objects_to_be_added, existing_records)
      # Pass in a list of attribute hashes from which instances of ActiveRecord models will be created,
      # and compare them to a list of existing records.
      # Return only the objects which would not be duplicates.
      # Additionally, if duplicates are found within the existing records, delete them.

      start_time = Time.current
      model_name = self.to_s
      logger.info "#{model_name} prevent_duplicates starting [concern]..."

      # Coming in, we have an array of hashes and an ActiveRecord::Relation.
      # Combine both lists into one array of hashes, with the existing departures first.
      # Use transform_keys on objects_to_be_added to ensure that all keys are strings and not symbols.
      object_list = existing_records.map(&:attributes) + objects_to_be_added.map { |d| d.transform_keys { |k| k.to_s } }

      # Create a tracking hash to remember which departures we've already seen
      already_seen = {}

      # Create a list of existing IDs to delete
      ids_to_purge = []

      # Move through the object list and check for duplicates
      object_list.each do |dep|
        tracking_key = self.tracking_key(dep)
        if already_seen[tracking_key]
          unless dep["id"].blank?
            # Always keep the record with the smaller ID, and delete the one with the larger ID.
            # If this method happens to be running in 2 processes with the same 2 duplicates, this way we always pick the same one to delete.
            ids_to_purge << [dep["id"], already_seen[tracking_key]["id"]].max
          end
        else
          already_seen[tracking_key] = dep
        end
      end

      # Delete pre-existing duplicates
      unless ids_to_purge.length == 0
        self.delete(ids_to_purge)
      end

      # Assemble result
      # Return the unique list of values, but only keep values having no ID.
      # This ensures we don't try to re-create existing records.
      result = already_seen.values.select { |dep| dep["id"].nil? }

      # Log results
      prevented_count = objects_to_be_added.length - result.length
      unless prevented_count == 0
        logger.info "prevent_duplicates: Deleted #{ids_to_purge.length} existing duplicate #{model_name.pluralize}"
        logger.info "prevent_duplicates: Prevented #{prevented_count} duplicate #{model_name.pluralize}"
        logger.info "prevent_duplicates: Filtered to #{result.length} unique objects"
      end
      logger.info "prevent_duplicates complete after #{(Time.current - start_time).round(2)} seconds"

      result
    end # method
  end # ClassMethods

end
