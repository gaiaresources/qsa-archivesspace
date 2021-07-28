# There's a bug in MySQL versions prior to 8.0 that can cause a newly created
# record to receive the same AUTO_INCREMENT id as a previously deleted record.
#
# Circumstances where this will happen are:
#
#  * A record of some type is created and then deleted
#
#  * MySQL is restarted
#
#  * A new record of that same type is created
#
# The bug is described here:
#
#   https://bugs.mysql.com/bug.php?id=199
#
# The short version: MySQL versions < 8.0 keep track of the next auto increment
# ID to assign for each table *in memory only*.  When the DB is restarted, the
# in-memory counter is recomputed as MAX(id) + 1 and the sequence starts from
# there.  Since any number of records following MAX(id) could have been deleted
# prior to the restart (and still represented in the `deleted_records` table as
# Tombstones), this is a problem.
#
# This class scans the deleted record table for any record whose ID is still in
# use in one of the live record tables.  When it finds one, it:
#
#  * Removes the tombstone
#
#  * Marks the record for reindex
#
#  * Allows plugin code to do its own cleanup by invoking registered callbacks
#  * (see below)
#
# All of this can go away once everyone moves off MySQL 5.x.


class ZombieRecordHunter

  def self.run!
    # Just a bit of randomness to avoid different backend instances syncing up in a
    # cluster.  Not the end of the world if they do; just saves effort.
    sleep rand(20)

    start_time = Time.now

    DB.open do |db|
      unless db.database_type == :mysql
        return
      end

      ASModel.all_models.each do |model|
        jsonmodel = model.my_jsonmodel(true)

        next unless jsonmodel && jsonmodel.schema['uri']
        next unless model.table_name && db.table_exists?(model.table_name)

        wildcard_query = build_wildcard(jsonmodel.schema['uri'])

        uri_col = Sequel.qualify(:deleted_records, :uri)

        zombies = []
        db[:deleted_records]
          .join(model.table_name, Sequel.qualify(model.table_name, :id) => Sequel.function(:substring_index, uri_col, "/", -1))
          .filter(Sequel.like(uri_col, wildcard_query))
          .select(uri_col,
                  Sequel.qualify(model.table_name, :id))
          .each do |zombie|

          parsed_ref = JSONModel.parse_reference(zombie[:uri])

          # We do a bit of extra URI checking because some URI patterns are prefixes of
          # others.  For example, Repository records have a URI like
          # /repositories/:repo_id, which matches any repository-scoped deleted record.
          # Most of those won't be repositories, though, so we drop them out.
          #
          if parsed_ref && (parsed_ref[:type] == jsonmodel.record_type)
            zombies << zombie
          end
        end

        next if zombies.empty?

        zombies.each do |zombie|
          Log.warn("Found record #{zombie[:uri]} marked as deleted but still in use.  Delete flag will be cleared.")
        end

        listeners.each do |listener|
          begin
            listener.call(db, model, zombies)
          rescue
            Log.warn("Zombie record listener raised (ignored) exception: #{$!}")
            Log.exception($!)
          end
        end

        db[:deleted_records].filter(:uri => zombies.map {|z| z[:uri]}).delete
        model.filter(:id => zombies.map {|z| z[:id]}).update(:system_mtime => Time.now)
      end
    end

    if AppConfig[:zombie_record_detection_print_timing]
      Log.debug("Zombie record hunter completed in %.2f seconds" % [Time.now - start_time])
    end
  end

  private

  def self.listeners
    @listeners ||= []
    @listeners
  end

  # Add custom code to be invoked when zombie records are found.  Callbacks are invoked like:
  #
  #  callback(db, model, zombies)
  #
  # Where:
  #
  #  * `db` is a Sequel connection with an open transaction
  #  * `model` is the ASModel for whom zombies have been found
  #  * `zombies` is a non-empty list of zombie records.  Each entry has `:uri` and `:id` keys to identify them.
  #
  def self.add_listener(&callback)
    @listeners ||= []
    @listeners << callback
  end

  # Turn a URI pattern like:
  #
  #  /repositories/:repo_id/archival_objects
  #
  # Into an (escaped) LIKE clause such as:
  #
  #  /repositories/%/archival\_objects/%
  #
  def self.build_wildcard(uri_pattern)
    base = uri_pattern.split('/').map {|s|
      if s.start_with?(':')
        '%'
      else
        s.gsub(/([%_])/) { '\\' + Regexp.last_match[1] }
      end
    }.join('/')

    "#{base}/%"
  end
end
