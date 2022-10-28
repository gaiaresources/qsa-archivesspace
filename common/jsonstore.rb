# Efficient storage for JSON strings
#
# The general idea: JSON strings are pretty verbose, but there's a lot of
# repetition--especially between runs of the same record type.  So, instead of
# storing individual JSON records individually, pack them together in groups and
# compress the whole group together.
#
# Works as follows:
#
#  * Records get added and stored in the `staging` table initially.
#
#  * Once BLOCK_SIZE records have been added, they get removed from `staging`,
#    concatenated and compressed using zstd.  The resulting chunk is called a
#    "block" and gets stored in the `block` table.
#
#  * The `record_location` table tracks all of the records that have been added.
#    Each entry will either have a `staging_id` or a `block_id` that indicates
#    where to find the record.  If `block_id` is set, `block_offset` and
#    `block_length` give you the byte range within the (uncompressed!) block to
#    look for the raw record.
#
#  * The `block_use_count` keeps track of how many records live in each block.
#    As new versions of records are added, versions in old blocks are
#    superseded, and their use counts are decremented accordingly.  When a
#    block's use count is zero, they're candidates for removal.
#
#
# Versioning
#
# Each stored record has a record_uri and a version number.  Since we commit
# records to the jsonstore prior to committing them to the Solr index, it would
# be possible for a Solr search to get version n-1 of an indexed document, but
# version n of the `json` source record embedded within it.
#
# We avoid this by storing each json record with a version number that gets
# indexed in Solr.  When pulling back json records for Solr result sets, we take
# the embedded version number and use it to pull the right version for the Solr
# record.
#
# Once a version of a record has been added and committed to Solr, any older
# versions in the JSON store can be removed.  We do this periodically (deleting
# any record older than 24 hours at present).
#

found_libs = false

['lib', 'common/lib'].each do |prefix|
  begin
    require File.absolute_path(File.join(ASUtils.find_base_directory, prefix, 'zstd-jni-1.5.2-4.jar'))
    require File.absolute_path(File.join(ASUtils.find_base_directory, prefix, 'sqlite-jdbc-3.39.3.0.jar'))
    found_libs = true
  rescue LoadError
  end
end

unless found_libs
  raise "Failed to load zstd & sqlite dependencies"
end

require 'sequel'

class JSONStore

  # The number of JSON records we store and compress in our `block` table.  Bigger
  # number: better compression but slower retrieval.
  BLOCK_SIZE = 32

  # When documents are replaced with newer versions, we keep old ones around for a
  # period in case any searches against an older index version are still running.
  # Delete them after 24 hours, which should be an extremely safe margin.
  EXPIRE_AGE_SECONDS = 86400

  def initialize(path)
    @db_path = path
    @write_lock = Mutex.new

    @needs_schema = true
  end

  def create_schema!
    with_db do |db|
      db.create_table?(:record_location) do
        primary_key :record_location_id
        String :record_uri, null: false
        Integer :version, null: false
        Integer :is_current, null: false

        Integer :block_id, index: true
        Integer :block_offset
        Integer :block_length
        Integer :staging_id, index: true

        index [:record_uri, :is_current]
        index [:record_uri, :version], unique: true
        index [:is_current, :version]
      end

      db.create_table?(:block) do
        primary_key :block_id
        File :block, null: false
        Integer :original_size, null: false
      end

      db.create_table?(:block_use_count) do
        primary_key :block_id
        Integer :count, null: false
      end

      db.create_table?(:staging) do
        primary_key :staging_id
        String :record_uri, null: false
        Integer :original_size, null: false
        File :json, null: false
      end
    end
  end

  def store_batch(uri_to_json, version)
    @write_lock.synchronize do
      if @needs_schema
        create_schema!
        @needs_schema = false
      end

      with_db do |db|
        db.transaction do |jdbc|
          # Not expecting this to happen in general, but just in case we get the same
          # record in the same instant.
          db[:record_location].filter(:record_uri => uri_to_json.keys, :version => version).delete
          db[:record_location].filter(:record_uri => uri_to_json.keys, :is_current => 1).update(:is_current => 0)

          rows = []
          uri_to_json.each do |uri, json|
            compressed = com.github.luben.zstd.Zstd.compress(json.to_java.get_bytes("UTF-8"))

            rows << {:record_uri => uri, :json => compressed, :original_size => json.bytesize}
          end

          insert_blobs = jdbc.prepareStatement("insert into staging (record_uri, json, original_size) values (?, ?, ?)",
                                               java.sql.Statement::RETURN_GENERATED_KEYS)

          staging_ids = []
          rows.each do |row|
            insert_blobs.setString(1, row.fetch(:record_uri))
            insert_blobs.setBytes(2, row.fetch(:json))
            insert_blobs.setInt(3, row.fetch(:original_size))

            insert_blobs.executeUpdate

            rs = insert_blobs.get_generated_keys

            while rs.next
              staging_ids << rs.get_int(1)
            end
          end

          db[:record_location].multi_insert(uri_to_json.keys.zip(staging_ids).map {|uri, staging_id| {:record_uri => uri, :version => version, :is_current => 1, :staging_id => staging_id}})

          repack!(db)
        end
      end
    end
  end

  RecordVersion = Struct.new(:record_uri, :version)

  def get_json(record_versions)
    result = {}

    return result if record_versions.empty?

    with_db do |db|
      db.transaction do
        filter = record_versions.map {|rv| Sequel.&({:record_uri => rv.record_uri, :version => rv.version})}

        db[:record_location].filter(Sequel.|(*filter)).all.group_by {|location| location[:block_id]}.each do |block_id, locations|
          if block_id.nil?
            # Staging area
            locations_by_staging_id = locations.group_by {|l| l[:staging_id]}

            db[:staging].filter(:staging_id => locations_by_staging_id.keys).each do |staging_row|
              location = locations_by_staging_id.fetch(staging_row[:staging_id]).first

              result[RecordVersion.new(location[:record_uri], location[:version])] =
                java.lang.String.new(com.github.luben.zstd.Zstd.decompress(staging_row[:json].to_java_bytes, staging_row[:original_size]))
            end
          else
            block = db[:block][:block_id => block_id]
            block_bytes = parse_block(block[:block], block[:original_size])

            locations.each do |location|
              result[RecordVersion.new(location[:record_uri], location[:version])] =
                java.lang.String.new(block_bytes, location[:block_offset], location[:block_length], "UTF-8")
            end
          end
        end
      end
    end

    result
  end

  private

  def with_db(&block)
    Sequel.connect("jdbc:sqlite:#{@db_path}") do |db|
      db.run("PRAGMA journal_mode = WAL")
      block.call(db)
    end
  end

  BlockEntry = Struct.new(:offset, :length)

  def build_block(records)
    out_bytes = java.io.ByteArrayOutputStream.new
    packed = java.io.DataOutputStream.new(out_bytes)

    record_offsets = {}

    records.each do |record|
      bytes = com.github.luben.zstd.Zstd.decompress(record[:json].to_java_bytes, record[:original_size])

      record_offsets[record[:staging_id]] = BlockEntry.new(out_bytes.size, bytes.length)

      packed.write(bytes, 0, bytes.length)
      packed.flush
    end

    packed.close

    [
      com.github.luben.zstd.Zstd.compress(out_bytes.to_byte_array),
      out_bytes.size,
      record_offsets
    ]
  end

  def parse_block(block, original_size)
    com.github.luben.zstd.Zstd.decompress(block.to_java_bytes, original_size)
  end

  def repack!(db)
    if rand < 0.001
      max_age_ms = java.lang.System.currentTimeMillis - (EXPIRE_AGE_SECONDS * 1000)

      record_versions_to_expire =
        db[:record_location].filter(:is_current => 0).where { version < max_age_ms }.filter(Sequel.~(:block_id => nil)).limit(1000).map(:record_location_id)

      # Decrement block counts
      db[:record_location].filter(:record_location_id => record_versions_to_expire).group_and_count(:block_id).each do |row|
        adjustment = 0 - row[:count]
        db[:block_use_count].filter(:block_id => row[:block_id]).update(:count => Sequel.expr(adjustment) + :count)
      end

      db[:record_location].filter(:record_location_id => record_versions_to_expire).delete

      # Run a GC cycle from time to time
      garbage_blocks = db[:block_use_count].filter(:count => 0).limit(5).map(:block_id)

      unless garbage_blocks.empty?
        if db[:record_location].filter(:block_id => garbage_blocks).count > 0
          $stderr.puts("BUG: garbage blocks should not have linked records: #{garbage_blocks.inspect}")
        else
          db[:block].filter(:block_id => garbage_blocks).delete
          db[:block_use_count].filter(:block_id => garbage_blocks).delete
        end
      end
    end

    while db[:staging].count > BLOCK_SIZE
      all_staging_entries = db[:staging].order(:staging_id).limit(BLOCK_SIZE).all
      record_locations_by_staging_id = db[:record_location]
                                         .filter(:staging_id => all_staging_entries.map {|r| r[:staging_id]})
                                         .map {|rl| [rl[:staging_id], rl]}
                                         .to_h

      # If we've deleted record_locations because we saw the same version in quick
      # succession, these don't get repacked since the entries are defunct.
      undeleted_staging_entries = all_staging_entries.reject {|staging| !record_locations_by_staging_id[staging[:staging_id]]}

      if !undeleted_staging_entries.empty?
        block, original_size, record_offsets = build_block(undeleted_staging_entries)

        block_id = db[:block].insert(:block => Sequel.blob(String.from_java_bytes(block)), :original_size => original_size)
        db[:block_use_count].insert(:block_id => block_id, :count => undeleted_staging_entries.length)

        db[:record_location].filter(:staging_id => undeleted_staging_entries.map {|r| r[:staging_id]}).delete

        db[:record_location].multi_insert(undeleted_staging_entries.map {|r|
                                            entry = record_offsets.fetch(r[:staging_id])
                                            old_record_location = record_locations_by_staging_id.fetch(r[:staging_id])
                                            {
                                              :record_uri => r[:record_uri],
                                              :version => old_record_location.fetch(:version),
                                              :is_current => old_record_location.fetch(:is_current),
                                              :block_id => block_id,
                                              :block_offset => entry.offset,
                                              :block_length => entry.length,
                                            }
                                          })
      end

      db[:staging].filter(:staging_id => all_staging_entries.map {|r| r[:staging_id]}).delete
    end
  end

end
