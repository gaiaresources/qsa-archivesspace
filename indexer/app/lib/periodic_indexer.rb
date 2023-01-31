require_relative 'indexer_common'
require_relative 'index_state'
require_relative 'index_state_s3'
require 'time'
require 'thread'
require 'java'
require 'log'

# Eagerly load this constant since we access it from multiple threads.  Having
# two threads try to load it simultaneously seems to create the possibility for
# race conditions.
java.util.concurrent.TimeUnit::MILLISECONDS

class PeriodicIndexer < IndexerCommon

  def initialize(backend_url = nil, state = nil, indexer_name = nil, verbose = true, config = {})
    super(backend_url || AppConfig[:backend_url], config)

    @indexer_name = indexer_name || 'PeriodicIndexer'
    state_class = config(:index_state_class).constantize
    state_name = config.has_key?(:state_key) ? "indexer_plugin_#{config[:state_key]}_state" : 'indexer_state'
    @state = state || state_class.new(state_name)
    @verbose = verbose

    # A small window to account for the fact that transactions might be committed
    # after the periodic indexer has checked for updates, but with timestamps from
    # prior to the check.
    @window_seconds = 30

    @time_to_sleep = config(:solr_indexing_frequency_seconds).to_i
    @thread_count = config(:indexer_thread_count).to_i
    @records_per_thread = config(:indexer_records_per_thread).to_i

    # Space out our request threads a little, such that half the threads are
    # waiting on the backend while the other half are mapping documents &
    # indexing.
    concurrent_requests = (@thread_count <= 2) ? @thread_count : (@thread_count.to_f / 2).ceil
    @backend_fetch_sem = java.util.concurrent.Semaphore.new(concurrent_requests)

    @timing = IndexerTiming.new
  end

  WORKER_STATUS_NOTHING_INDEXED = 0
  WORKER_STATUS_INDEX_SUCCESS = 1
  WORKER_STATUS_INDEX_ERROR = 2

  def start_worker_thread(queue, record_type)
    repo_id = JSONModel.repository
    session = JSONModel::HTTP.current_backend_session

    Thread.new do
      # Each worker thread will yield a value (Thread.value) indicating either
      # "did nothing", "complete success" or "errors encountered".
      worker_status = WORKER_STATUS_NOTHING_INDEXED

      begin
        # Inherit the repo_id and user session from the parent thread
        JSONModel.set_repository(repo_id)
        JSONModel::HTTP.current_backend_session = session

        while true
          id_subset = queue.poll(10000, java.util.concurrent.TimeUnit::MILLISECONDS)

          # If the parent thread has finished, it should have pushed a :finished
          # token.  But if we time out after a reasonable amount of time, assume
          # it isn't coming back.
          break if (id_subset == :finished || id_subset.nil?)

          records = @timing.time_block(:record_fetch_ms) do
            @backend_fetch_sem.acquire
            begin
              # Happy path: we request all of our records in one shot and
              # everything goes to plan.
              begin
                fetch_records(record_type, id_subset, resolved_attributes)
              rescue
                worker_status = WORKER_STATUS_INDEX_ERROR

                # Sad path: the fetch failed for some reason, possibly because
                # one or more records are malformed and triggering a bug
                # somewhere.  Recover as best we can by fetching records
                # individually.
                salvaged_records = []

                id_subset.each do |id|
                  begin
                    salvaged_records << fetch_records(record_type, [id], resolved_attributes)[0]
                  rescue
                    # Not seeing new workers get started?
                    Log.error("Failed fetching #{record_type} id=#{id}: #{$!}")
                  end
                end

                salvaged_records
              end
            ensure
              @backend_fetch_sem.release
            end
          end

          if !records.empty?
            if worker_status == WORKER_STATUS_NOTHING_INDEXED
              worker_status = WORKER_STATUS_INDEX_SUCCESS
            end

            begin
              # Happy path: index all of our records in one shot
              index_records(records.map {|record|
                              {
                                'record' => record,
                                'uri' => record.fetch('uri')
                              }
                            })
            rescue
              worker_status = WORKER_STATUS_INDEX_ERROR

              # Sad path: indexing of one or more records failed, possibly due
              # to weird data or bugs in mapping rules.  Index as much as we
              # can before reporting the error.
              records.each do |record|
                begin
                  index_records([
                                  {
                                    'record' => record,
                                    'uri' => record.fetch('uri')
                                  }
                                ])
                rescue
                  Log.error("Failure while indexing record: #{record.fetch('uri')}: #{$!}")
                  Log.exception($!)
                end
              end
            end
          end
        end

        worker_status
      rescue
        Log.error("Failure in #{@indexer_name} worker thread: #{$!}")
        Log.error($@.join("\n"))

        return WORKER_STATUS_INDEX_ERROR
      end
    end
  end


  def load_bitset(ids)
    result = java.util.BitSet.new

    ids.each do |id|
      result.set(id)
    end

    result
  end

  # Keep track of the set of IDs that were indexed for each record type during the
  # previous indexing run.  We use this to avoid double-indexing records that were
  # changed within the @window_seconds commit window when indexing large numbers
  # of changes.
  IDS_INDEXED_ON_LAST_RUN = {}

  def run_index_round
    log("Running index round")

    login

    # Index any repositories that were changed
    start = Time.now
    repositories = JSONModel(:repository).all('resolve[]' => resolved_attributes)

    modified_since = [@state.get_last_mtime('repositories', 'repositories') - @window_seconds, 0].max
    updated_repositories = repositories.reject {|repository| Time.parse(repository['system_mtime']).to_i < modified_since}.
    map {|repository| {
        'record' => repository.to_hash(:raw),
        'uri' => repository.uri
      }
    }

    # indexing repos is usually easy, since its unlikely there will be lots of
    # them.
    if !updated_repositories.empty?
      index_records(updated_repositories)
      send_commit
    end

    @state.set_last_mtime('repositories', 'repositories', start)

    # And any records in any repositories
    repositories.each_with_index do |repository, i|
      JSONModel.set_repository(repository.id)

      checkpoints = []

      record_types.each do |type|
        next if @@global_types.include?(type) && i > 0
        start = Time.now

        # Find any records that might have been committed within the check window that
        # we missed on the last run.  For example, maybe we checked at T5 but at T7 a
        # commit happened that wrote an update with system_mtime=T3.  It can happen!
        # Rows get timestamped at the point they're inserted/updated, but they might get
        # committed seconds later than that.
        #
        # Note that we look backwards by the larger of @window_seconds (30 seconds at
        # time of writing) and @time_to_sleep (which is however often the periodic
        # indexer runs).  The thinking here is that we want to make sure the window is
        # always long enough to cover a really slow database commit, so making sure it's
        # no less than @window_seconds helps to ensure that.  That way, we still look
        # back far enough, even if someone has set their indexer to poll once per
        # second.
        #
        # BUT, if the indexing frequency is set to more than 30 seconds, we might as
        # well look back over the entire time span of the last indexing run.  The extra
        # cost is negligible, our bitset will avoid doing duplicate indexing work, and
        # maybe it very occasionally catches a record that would have been missed
        # otherwise..
        #
        modified_since_with_window = [0, @state.get_last_mtime(repository.id, type) - [@window_seconds, @time_to_sleep].max,].max
        ids_missed_on_last_run = load_bitset(JSONModel::HTTP.get_json(JSONModel(type).uri_for,
                                                                      :all_ids => true,
                                                                      :modified_since => modified_since_with_window,
                                                                      :modified_before => @state.get_last_mtime(repository.id, type)))

        # Remove any IDs that we already indexed last time
        ids_missed_on_last_run.andNot(IDS_INDEXED_ON_LAST_RUN.fetch(type) { java.util.BitSet.new })

        # we get all the ids of this record type out of the repo
        id_set = JSONModel::HTTP.get_json(JSONModel(type).uri_for, :all_ids => true, :modified_since => @state.get_last_mtime(repository.id, type)) || ''

        # Index ids_missed_on_last_run too.
        ids_missed_on_last_run.size.times do |i|
          if ids_missed_on_last_run.get(i)
            id_set << i
          end
        end

        skip_file = "/tmp/skip_#{type}_index_ids.dat"
        ids_to_skip = []

        if File.exist?(skip_file)
          $stderr.puts("Loading records to skip from: #{skip_file}")

          File.open(skip_file, "r") do |fh|
            while skip_id = fh.gets
              next if skip_id == ''
              ids_to_skip << Integer(skip_id)
            end
          end

          $stderr.puts("Found #{ids_to_skip.length} IDs to skip")

          File.unlink(skip_file)
        end

        id_set -= ids_to_skip

        indexed_count = 0

        work_queue = java.util.concurrent.LinkedBlockingQueue.new(@thread_count)

        workers = (0...@thread_count).map {|thread_idx|
          start_worker_thread(work_queue, type)
        }

        begin
          # Feed our worker threads subsets of IDs to process
          id_set.each_slice(@records_per_thread) do |id_subset|
            # This will block if all threads are currently busy indexing.
            while !work_queue.offer(id_subset, 5000, java.util.concurrent.TimeUnit::MILLISECONDS)
              # The work queue is full.  Threads might just be busy, but check
              # for failed workers too.

              # If any of the workers have caught an exception, rethrow it immediately
              workers.each do |thread|
                thread.value if thread.status.nil?
              end
            end

            indexed_count += id_subset.length
            log("~~~ Indexed #{indexed_count} of #{id_set.length} #{type} records in repository #{repository.repo_code}")
          end
        ensure
          # Once we're done, instruct the workers to finish up.
          @thread_count.times { work_queue.offer(:finished, 5000, java.util.concurrent.TimeUnit::MILLISECONDS) }
        end

        # If any worker reports that they indexed some records, we'll send a
        # commit.
        worker_statuses = workers.map {|thread|
            thread.join
            thread.value
        }

        # Commit if anything was added to Solr
        unless worker_statuses.all? {|status| status == WORKER_STATUS_NOTHING_INDEXED}
          send_commit
          log("Indexed #{id_set.length} records in #{Time.now.to_i - start.to_i} seconds")
        end

        if worker_statuses.include?(WORKER_STATUS_INDEX_ERROR)
          Log.info("Skipping update of indexer state for record type #{type} in repository #{repository.id} due to previous failures")
        else
          IDS_INDEXED_ON_LAST_RUN[type] = load_bitset(id_set)
          @state.set_last_mtime(repository.id, type, start)
        end
      end

      index_round_complete(repository)
    end

    handle_deletes

    log("Index round complete")
  end

  def index_round_complete(repository)
    # Give subclasses a place to hang custom behavior.
  end

  def handle_deletes(opts = {})
    start = Time.now
    last_mtime = @state.get_last_mtime('_deletes', 'deletes')
    did_something = false

    page = 1
    while true
      deletes = JSONModel::HTTP.get_json("/delete-feed", :modified_since => [last_mtime - @window_seconds, 0].max, :page => page, :page_size => @records_per_thread)

      if !deletes['results'].empty?
        did_something = true
      end

      delete_records(deletes['results'], opts)

      break if deletes['last_page'] <= page

      page += 1
    end

    if did_something
      send_commit
    end

    @state.set_last_mtime('_deletes', 'deletes', start)
  end

  def run
    while true
      begin
        run_index_round unless paused?
      rescue
        reset_session
        Log.error($!.backtrace.join("\n"))
        Log.error($!.inspect)
      end

      sleep @time_to_sleep
    end
  end

  # used for just info lines
  def log(line)
    Log.info("#{@indexer_name} [#{Time.now}] #{line}")
  end

  def self.get_indexer(state = nil, name = "Staff Indexer")
    indexer = self.new(AppConfig[:backend_url], state, name)
  end


  def self.get_plugin_indexer(config, state = nil, verbose = true)
    # We need to protect against a poorly defined plugin indexer
    # messing with the state of the built-in indexers
    if !config.has_key?(:state_key) || config[:state_key].length < 1
      raise "Plugin Indexer config must have a :state_key defined"
    end

    self.new(AppConfig[:backend_url], state, config[:name], verbose, config)
  end


  def fetch_records(type, ids, resolve)
    uri = JSONModel(type).my_url(nil)
    uri.query = URI.encode_www_form(:id_set => ids.join(","), 'resolve[]' => resolve)
    response = JSONModel::HTTP.get_response(uri)

    if response.code == '200'
      ASUtils.json_parse(response.body)
    elsif response.code == '403'
      raise AccessDeniedException.new
    else
      raise response.body
    end
  end

end
