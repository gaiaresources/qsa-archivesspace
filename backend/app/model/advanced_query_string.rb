require 'time'

class AdvancedQueryString
  def initialize(query, use_literal: false, protect_unpublished: false)
    @query = query.transform_keys { |k| k.to_s }
    @use_literal = use_literal
    @protect_unpublished = protect_unpublished
  end

  def to_solr_s
    return empty_solr_s if empty_search?

    solr_field = AdvancedSearch.solr_field_for(@query.fetch('field'))
    record_type_limit = AdvancedSearch.record_type_limit(@query.fetch('field'))

    if solr_field.respond_to?(:to_solr_s)
      "#{prefix}(#{solr_field.to_solr_s(@query)})"
    else
      query = if field.nil?
                "#{prefix}#{value}"
              else
                "#{prefix}#{field}:#{value}"
              end

      if record_type_limit
        query = "(%s) AND types:(%s)" % [
          query,
          record_type_limit.join(' OR ')
        ]
      end

      query
    end
  end

  private

  def use_literal?
    @use_literal
  end

  def empty_solr_s
    if negated?
      if date?
        "#{field}:[* TO *]"
      else
        "#{field}:['' TO *]"
      end
    else
      record_type_limit = AdvancedSearch.record_type_limit(@query.fetch('field'))

      if record_type_limit
        "(types:(%s) NOT %s:*)" % [record_type_limit.join(' OR '), field]
      else
      "(*:* NOT #{field}:*)"
    end
  end
  end

  def prefix
    negated? ? "-" : ""
  end

  def field
    if exact_match_search?
      AdvancedSearch.solr_field_for_exact_match(@query['field'])
    else
      AdvancedSearch.solr_field_for(@query['field'], protect_unpublished: @protect_unpublished)
    end
  end

  def value
    if date?
      comparator = @query["comparator"]
      precision = @query["precision"].upcase
      date = JSONModel::Validations.normalise_date(@query["value"])
      time = Time.parse(date).utc.iso8601

      case comparator
      when "greater_than" then "[#{time}+1#{precision} TO *]"
      when "lesser_than" then "[* TO #{time}-1MILLISECOND]"
      when "equal" then "[#{time} TO #{time}+1#{precision}-1MILLISECOND]"
      end

    elsif @query["jsonmodel_type"] == "range_query"
      "[#{@query["from"] || '*'} TO #{@query["to"] || '*'}]"
    elsif @query["jsonmodel_type"] == "series_system_query"
      ref = nil    # Won't match anything by default...
      parsed_qsaid = {}

      if @query['value']
        parsed_qsaid = QSAId.parse_prefixed_id(@query['value'].upcase)

        # take the provided value, but we'll try to match it up with the
        # corresponding record model and ID in a moment
        ref = @query['value']

        unless parsed_qsaid.empty? || parsed_qsaid[:model].nil?
        row = parsed_qsaid[:model].filter(:qsa_id => parsed_qsaid[:id]).select(:id).first
        record_id = (row || {})[:id]

        if record_id
          ref = parsed_qsaid[:model].my_jsonmodel.uri_for(record_id, :repo_id => RequestContext.get(:repo_id))
        end
      end
      end

      if ref
        '("%s::%s")' % [@query['relator'], ref]
      else
        # Just query on the relator
        @query['relator']
      end

    elsif @query["jsonmodel_type"] == "field_query" && (use_literal? || @query["literal"])
      "(\"#{solr_escape(@query['value'])}\")"
    elsif exact_match_search?
      "(\"#{solr_escape(@query['value'])}\")"
    else
      "(#{replace_reserved_chars(@query['value'].to_s)})"
    end
  end

  def exact_match_search?
    @query["comparator"] == "equals"
  end

  def empty_search?
    if @query["jsonmodel_type"] == "date_field_query"
      @query["comparator"] == "empty"
    elsif @query["jsonmodel_type"] == "boolean_field_query"
      false
    elsif @query["jsonmodel_type"] == "field_query"
      @query["comparator"] == "empty"
    elsif @query["jsonmodel_type"] == "range_query"
      false
    elsif @query["jsonmodel_type"] == "series_system_query"
      false
    else
      raise "Unknown field query type: #{@query["jsonmodel_type"]}"
    end
  end

  def negated?
    @query['negated']
  end

  def date?
    @query["jsonmodel_type"] == "date_field_query"
  end


  SOLR_CHARS = '+-&|!(){}[]^"~*?:\\/'
  RESERVED_CHARS = ':'

  def solr_escape(s)
    pattern = Regexp.quote(SOLR_CHARS)
    s.gsub(/([#{pattern}])/, '\\\\\1')
  end

  def replace_reserved_chars(s)
    pattern = Regexp.quote(RESERVED_CHARS)
    s.gsub(/([#{pattern}])/, ' ')
  end
end
