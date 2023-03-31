# Resolving is the process of taking one or more records with embedded URI links
# (refs) and inlining the JSON of those linked records.
#
# For example, if we have:
#
#  {'title' => "Some Archival Object", 'resource' => {'ref' => '/repositories/2/resources/123'}}
#
# Then resolving this document on "resource" would return:
#
# {
#  'title' => "Some Archival Object",
#  'resource' => {
#    'ref' => '/repositories/2/resources/123',
#    '_resolved' => {
#       'title' => "Some Resource Record",
#       ...
#     }
#  }
# }
#
# You can resolve more than one record at once and more than one ref type at
# once.  You can also resolve a ref within a resolved record by creating a path
# of refs with double colons, like "resource::linked_agent".

module URIResolver

  include JSONModel

  def self.add_resolve_wrapper(wrapper)
    @resolve_wrappers ||= []
    @resolve_wrappers << wrapper
  end

  def self.resolve_wrappers
    @resolve_wrappers ||= []
  end

  # Additional `ignored` argugment to account for callers using the old API
  # which required an `env`.  In the long-run, we can get rid of this.
  def resolve_references(records, properties_to_resolve, ignored = nil)
    if ignored
      msg = ('Three-argment call to resolve_references is deprecated.' +
             'The "env" parameter is no longer needed.')

      if ASpaceEnvironment.environment == :unit_test
        raise msg
      else
        Log.warn(msg)
      end
    end

    result = if properties_to_resolve
               URIResolverImplementation.new(properties_to_resolve).resolve_references(records)
             else
               records
             end

    URIResolver.resolve_wrappers.each do |resolve_wrapper|
      result = resolve_wrapper.resolve(result, records, properties_to_resolve)
    end

    result
  end

  module_function :resolve_references

  # Allow API consumers (such as plugins) to hook into the resolving process
  def self.register_resolver(resolver)
    URIResolverImplementation.register_resolver(resolver)
  end

  def self.ensure_reference_is_valid(reference, active_repository = nil)
    URIResolverImplementation.new([]).ensure_reference_is_valid(reference, active_repository)
  end

  class URIResolverImplementation

    include JSONModel

    def initialize(properties_to_resolve)
      @properties_to_resolve = parse_properties(properties_to_resolve)
    end

    def self.resolvers
      @resolvers ||= [TreeResolver, ASModelResolver]
    end

    def self.register_resolver(resolver)
      resolvers.insert(0, resolver)
    end

    def ensure_reference_is_valid(uri, active_repository_id = nil)
      parsed = JSONModel.parse_reference(uri)

      # error on anything that points outside the active repository
      if active_repository_id && \
         parsed[:repository] && \
         JSONModel.parse_reference(parsed[:repository])[:id] != active_repository_id

        raise ReferenceError.new("Inter-repository links are not allowed in this operation! (Bad link: '#{uri}'; Active repo: '#/repositories/#{active_repository_id}')")
      end

      resolver = get_resolver_for_type(parsed[:type])

      if resolver && !resolver.record_exists?(uri)
        raise ReferenceError.new("Reference does not exist! (Reference: '#{uri}')")
      end
    end

    # Walk 'value', find all refs, resolve them
    def resolve_references(value)
      return value if @properties_to_resolve.empty?

      # Make sure we have an array, even if there's just one record to resolve
      was_wrapped = false
      if value.is_a?(Array)
        records = value
      else
        records = ASUtils.wrap(value)
        was_wrapped = true
      end

      # Any JSONModels can become vanilla hashes
      records = records.map {|value|
        if value.is_a?(JSONModelType)
          value.to_hash(:trusted)
        else
          value
        end
      }

      records = JSON.parse(records.to_json)

      pending_resolve = records
      max_depth = @properties_to_resolve.map(&:length).max

      max_depth.times do |depth|
        property_set = Set.new(@properties_to_resolve.map {|properties| properties[depth]}.compact)

        refs_to_resolve = find_matching_refs(pending_resolve, property_set)

        resolved = fetch_records_by_uri(refs_to_resolve.map {|ref| ref['ref']})

        next_pending_resolve = []

        refs_to_resolve.each do |ref|
          uri = ref['ref']
          if resolved.has_key?(uri)
            ref['_resolved'] = resolved.fetch(uri)
            next_pending_resolve << ref['_resolved']
          end
        end

        pending_resolve = next_pending_resolve
      end

      # Return the same type we were given
      was_wrapped ? records[0] : records
    end

    private

    def find_matching_refs(to_search, property_set, last_key = nil)
      result = []

      if to_search.is_a?(Hash)
        if to_search['ref']
          if property_set.include?(last_key)
            result << to_search
          end
        end
          to_search.each do |k, v|
            result.concat(find_matching_refs(v, property_set, k))
            end
      elsif to_search.is_a?(Array)
        to_search.each_with_index do |v, idx|
          result.concat(find_matching_refs(v, property_set, last_key))
        end
      end

      result
    end

    def fetch_records_by_uri(record_uris)
      result = {}

      record_uris.group_by {|uri|
        parsed_uri = JSONModel.parse_reference(uri) or raise "Invalid URI: #{uri}"
        [parsed_uri[:repository], parsed_uri[:type]]
      }.each do |(repo_uri, record_type), uris|
        resolver = get_resolver_for_type(record_type)

        resolver.resolve(uris).each do |uri, json|
          result[uri] = json
        end
      end

      result
    end


    def is_ref?(val)
      val.is_a?(Hash) && val.has_key?('ref')
    end


    def get_resolver_for_type(record_type)
      self.class.resolvers.each do |resolver|
        handler = resolver.handler_for(record_type)
        return handler if handler
      end

      raise "Could not find a resolver for type: #{record_type.inspect}"
    end

    # nested resolve requests are delimited by '::' like a::b::c
    #
    # Split them into their parts ['a', 'b', 'c'] and yield all prefixes like
    # [['a'], ['a', 'b'], ['a', 'b', 'c']]
    def parse_properties(properties)
      properties.map {|property|
        parts = property.split('::')
        (1..parts.length).map {|i| parts.take(i)}
      }.flatten(1).uniq
    end

  end


  class ResolverType
    # Given a JSONModel type symbol (like :archival_object, :accession or
    # :resource), return a resolver capable of getting back JSON records for
    # that type.
    #
    # Returns nil if this resolver isn't applicable to that type.
    def self.handler_for(record_type)
      raise NotImplementedError.new("This method must be overriden by the implementing class")
    end

    # Given a list of record URI strings (like
    # "/repositories/2/archival_objects/123"), return an Enumerator yielding
    # |record_uri_string, record_json|
    def resolve(uris)
      raise NotImplementedError.new("This method must be overriden by the implementing class")
    end

    # True if a record (identified by URI) actually exists in the database
    def record_exists?(uri)
      raise NotImplementedError.new("This method must be overriden by the implementing class")
    end
  end


  # A resolver for all standard ArchivesSpace record types (accession, resource,
  # archival_object, digital_object, etc.)
  class ASModelResolver < ResolverType

    def self.handler_for(jsonmodel_type)
      model = find_model_by_jsonmodel_type(jsonmodel_type)
      new(model) if model
    end

    def initialize(model)
      @model = model
    end

    def record_exists?(uri)
      id = JSONModel.parse_reference(uri)[:id]

      id && !@model[id].nil?
    end

    def resolve(uris)
      ids_by_repo = group_by_repo_id(uris)

      Enumerator.new do |yielder|
        ids_by_repo.each do |repo_id, parsed_repo_uris|
          ids = parsed_repo_uris.map {|parsed| parsed[:id]}

          # Set our active repo just in case any of the models rely on it
          RequestContext.open(:repo_id => repo_id) do
            @model.sequel_to_jsonmodel(@model.any_repo.filter(:id => ids).all).each do |json|
              yielder << [json.uri, json.to_hash(:trusted)]
            end
          end
        end
      end
    end

    private

    # Parse and group a set of URIs by Repository ID
    #
    # Returns a hash like:
    #
    # {
    #   2 => [{:repository => "/repositories/2", :type => "archival_objects", :id => 1},
    #         {:repository => "/repositories/2", :type => "archival_objects", :id => 2}],
    #   3 => [{:repository => "/repositories/3", :type => "archival_objects", :id => 3},
    #         {:repository => "/repositories/3", :type => "archival_objects", :id => 4}]
    # }
    #
    # Any global record types will have a key of `nil`
    def group_by_repo_id(uris)
      result = {}

      uris.each do |uri|
        parsed = JSONModel.parse_reference(uri)
        repo_id = parsed[:repository] ? JSONModel.parse_reference(parsed[:repository])[:id] : nil

        result[repo_id] ||= []
        result[repo_id] << parsed
      end

      result
    end

    def self.find_model_by_jsonmodel_type(type)
      ASModel.all_models.find {|model|
        jsonmodel = model.my_jsonmodel(true)
        jsonmodel && jsonmodel.record_type == type
      }
    end
  end


  # A resolver for the record tree types (resource, digital object &
  # classification trees)
  class TreeResolver < ResolverType

    def self.handler_for(jsonmodel_type)
      model = model_for_tree(jsonmodel_type)
      new(model) if model
    end

    def initialize(model)
      @model = model
    end

    def resolve(uris)
      Enumerator.new do |yielder|
        uris.each do |uri|
          id = JSONModel.parse_reference(uri)[:id]
          yielder << [uri, @model[id].tree.to_hash(:trusted)]
        end
      end
    end

    def record_exists?(uri)
      # Trees have historically been given a free pass here, and it seems that
      # the current unit tests are relying on this.  I guess it's never caused a
      # problem, but this could conceivably do the same check as the regular
      # ASModel resolver.
      true
    end

    private

    def self.model_for_tree(type)
      if type.to_s.end_with?('_tree')
        base_model_type = type.to_s.gsub(/_tree$/, '')

        ASModel.all_models.find {|model|
          jsonmodel = model.my_jsonmodel(true)
          jsonmodel && jsonmodel.record_type == base_model_type
        }
      end
    end
  end

end
