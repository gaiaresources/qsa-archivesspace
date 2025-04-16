class ArchivesSpaceService < Sinatra::Base

  Endpoint.get('/terms')
    .description("Get a list of Terms matching a prefix")
    .params(["q", String, "The prefix to match"])
    .permissions([])
    .returns([200, "[(:term)]"]) \
  do
    query = params[:q].gsub(/[%]/, '').downcase
    listing_response(Term
                       .filter(Sequel.like(Sequel.function(:lower, :term),
                                "#{query}%"))
                       .limit(20),
                     Term)
  end

end
