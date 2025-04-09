require 'advanced_query_builder'

class SearchController < ApplicationController

  set_access_control "view_repository" => [:do_search, :advanced_search]

  include ExportHelper

  def advanced_search
    criteria = params_for_backend_search

    queries = advanced_search_queries

    queries = queries.reject{|field|
      if field['type'] === 'range'
        field['from'].nil? && field['to'].nil?
      elsif field['type'] === 'series_system'
        false
      else
      (field["value"].nil? || field["value"] == "") && !field["empty"]
      end
    }

    if not queries.empty?
      if criteria['aq']
        existing_filter = ASUtils.json_parse(criteria['aq'])
        criteria['aq'] =  JSONModel::JSONModel(:advanced_query).from_hash({
                              query: JSONModel(:boolean_query)
                                       .from_hash({
                                                    :jsonmodel_type => 'boolean_query',
                                                    :op => 'AND',
                                                    :subqueries => [existing_filter['query'], AdvancedQueryBuilder.build_query_from_form(queries)['query']]
                                                  })
                            }).to_json
      else
        criteria["aq"] = AdvancedQueryBuilder.build_query_from_form(queries).to_json
      end
      criteria['facet[]'] = SearchResultData.BASE_FACETS
    end

    respond_to do |format|
      format.json {
        @search_data = Search.all(session[:repo_id], criteria)
        render :json => @search_data
      }
      format.js {
        @search_data = Search.all(session[:repo_id], criteria)
        if params[:listing_only]
          render_aspace_partial :partial => "search/listing"
        else
          render_aspace_partial :partial => "search/results"
        end
      }
      format.html {
        @search_data = Search.all(session[:repo_id], criteria)
        render "search/do_search"
      }
      format.csv {
        uri = "/repositories/#{session[:repo_id]}/search"
        csv_response( uri, Search.build_filters(criteria), "#{t('search_results.title').downcase}." )
      }
    end
  end

  def do_search
    criteria = params_for_backend_search.merge({"facet[]" => SearchResultData.BASE_FACETS.concat(params[:facets]||[]).uniq})

    context_criteria = params["context_filter_term"] ? {"filter_term[]" => params["context_filter_term"]} : {}

    # linker typeaheads should always sort by score
    context_criteria["sort"] = "score desc" if params["linker"]

    @search_data = Search.all(session[:repo_id], criteria, context_criteria)
    @hide_sort_options = params[:hide_sort_options] == "true"
    @hide_csv_download = params[:hide_csv_download] == "true"

    if params[:q] && params[:q].end_with?("*")
      # Typeahead search from a linker using wildcards.  These interact badly
      # with stemming because the wildcard causes query analysis to be skipped,
      # so stemming isn't applied to the query.
      #
      # This manifests in real data when you typeahead for "agency*" and get no
      # matches.  That term is stemmed to "agenc".
      #
      # Try to minimise the weird effects of this by searching for the
      # non-wildcard version as well.  The real solution here is to stop using
      # wildcards and use an ngram field instead.
      q = params[:q]

      params[:q] = "(#{q}) OR (#{q.gsub('*', '')})"
    end

    respond_to do |format|
      format.json {
        render :json => @search_data
      }
      format.js {
        if params[:listing_only]
          render_aspace_partial :partial => "search/listing"
        else
          render_aspace_partial :partial => "search/results"
        end
      }
      format.html {
        # default render
      }
      format.csv {
        criteria = params_for_backend_search.merge({"facet[]" => SearchResultData.BASE_FACETS})
        uri = "/repositories/#{session[:repo_id]}/search"

        # The 'context' field (shown as the "Found in" column for text searches) does not actually exist in the backend;
        # it is derived from the 'ancestors' field at runtime. If it shows up in the fields for the CSV download, we
        # need special processing to populate it properly. (See ANW-1509)
        if false # ASUtils.wrap(criteria['fields[]']).include? 'context'
          criteria['fields[]'].delete 'context'
          criteria['fields[]'].append *ContextConverter.ancestor_fields

          send_data csv_export_with_context(uri, Search.build_filters(criteria)),
            filename: "#{t('search_results.title').downcase}.#{Time.now.to_i}.csv"
        else
          # the old way (should generally be faster)
          csv_response(uri, Search.build_filters(criteria), "#{t('search_results.title').downcase}.")
        end
      }
    end
  end

end
