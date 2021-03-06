# Author:: Couchbase <info@couchbase.com>
# Copyright:: 2011 Couchbase, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module Couchbase

  module Error
    class View < Base
      attr_reader :from, :reason

      def initialize(from, reason)
        @from = from
        @reason = reason
        super("#{from}: #{reason}")
      end
    end
  end

  # This class implements Couchbase View execution
  #
  # @see http://www.couchbase.com/docs/couchbase-manual-2.0/couchbase-views.html
  class View
    include Enumerable

    # Set up view endpoint and optional params
    #
    # @param [ Couchbase::Bucket ] bucket Connection object which
    #   stores all info about how to make requests to Couchbase views.
    #
    # @param [ String ] endpoint Full CouchDB view URI.
    #
    # @param [ Hash ] params Optional parameter which will be passed to
    #   Couchbase::View#each
    #
    def initialize(bucket, endpoint, params = {})
      @bucket = bucket
      @endpoint = endpoint
      @params = params
      @wrapper_class = params.delete(:wrapper_class) || ViewRow
      unless @wrapper_class.respond_to?(:wrap)
        raise ArgumentError, "wrapper class should reposond to :wrap, check the options"
      end
    end

    # Yields each document that was fetched by view. It doesn't instantiate
    # all the results because of streaming JSON parser. Returns Enumerator
    # unless block given.
    #
    # @example Use each method with block
    #
    #   view.each do |doc|
    #     # do something with doc
    #   end
    #
    # @example Use Enumerator version
    #
    #   enum = view.each  # request hasn't issued yet
    #   enum.map{|doc| doc.title.upcase}
    #
    # @example Pass options during view initialization
    #
    #   endpoint = "http://localhost:5984/default/_design/blog/_view/recent"
    #   view = View.new(conn, endpoint, :descending => true)
    #   view.each do |document|
    #     # do something with document
    #   end
    #
    # @param [ Hash ] params Params for Couchdb query. Some useful are:
    #   :startkey, :startkey_docid, :descending.
    #
    def each(params = {})
      return enum_for(:each, params) unless block_given?
      fetch(params) {|doc| yield(doc)}
    end

    # Registers callback function for handling error objects in view
    # results stream.
    #
    # @yieldparam [String] from Location of the node where error occured
    # @yieldparam [String] reason The reason message describing what
    #   happened.
    #
    # @example Using <tt>#on_error</tt> to log all errors in view result
    #
    #     # JSON-encoded view result
    #     #
    #     # {
    #     #   "total_rows": 0,
    #     #   "rows": [ ],
    #     #   "errors": [
    #     #     {
    #     #       "from": "127.0.0.1:5984",
    #     #       "reason": "Design document `_design/testfoobar` missing in database `test_db_b`."
    #     #     },
    #     #     {
    #     #       "from": "http:// localhost:5984/_view_merge/",
    #     #       "reason": "Design document `_design/testfoobar` missing in database `test_db_c`."
    #     #     }
    #     #   ]
    #     # }
    #
    #     view.on_error do |from, reason|
    #       logger.warn("#{view.inspect} received the error '#{reason}' from #{from}")
    #     end
    #     docs = view.fetch
    #
    # @example More concise example to just count errors
    #
    #     errcount = 0
    #     view.on_error{|f,r| errcount += 1}.fetch
    #
    def on_error(&callback)
      @on_error = callback
      self  # enable call chains
    end

    # Performs query to CouchDB view. This method will stream results if block
    # given or return complete result set otherwise. In latter case it defines
    # method <tt>total_rows</tt> returning corresponding entry from CouchDB
    # result object.
    #
    # @param [Hash] params parameters for CouchDB query. See here the full
    #   list: http://wiki.apache.org/couchdb/HTTP_view_API#Querying_Options
    #
    # @yieldparam [Couchbase::ViewRow] document
    #
    # @return [Array] with documents. There will be <tt>total_entries</tt>
    #   method defined on this array if it's possible.
    #
    # @raise [Couchbase::Error::View] when <tt>on_error</tt> callback is nil and
    #   error object found in the result stream.
    #
    # @example Query +recent_posts+ view with key filter
    #   doc.recent_posts(:body => {:keys => ["key1", "key2"]})
    def fetch(params = {})
      params = @params.merge(params)
      body = params.delete(:body)
      if body && !body.is_a?(String)
        body = Yajl::Encoder.encode(body)
      end
      path = Utils.build_query(@endpoint, params)
      request = @bucket.make_couch_request(path, :body => body, :chunked => true)

      document_extractor = lambda do |iter, acc|
        path, obj = iter.next
        if acc
          if path == "/total_rows"
            # if total_rows key present, save it and take next object
            total_rows = obj
            path, obj = iter.next
          end
        end
        loop do
          if path == "/errors/"
            from, reason = obj["from"], obj["reason"]
            if @on_error
              @on_error.call(from, reason)
            else
              raise Error::View.new(from, reason)
            end
          else
            if acc
              acc << @wrapper_class.wrap(@bucket, obj)
            else
              yield @wrapper_class.wrap(@bucket, obj)
            end
          end
          path, obj = iter.next
        end
        if acc
          acc.instance_eval("def total_rows; #{total_rows}; end")
        end
      end

      if block_given?
        iter = YAJI::Parser.new(request).each(["/rows/", "/errors/"], :with_path => true)
        document_extractor.call(iter, nil) rescue StopIteration
      else
        iter = YAJI::Parser.new(request).each(["/total_rows", "/rows/", "/errors/"], :with_path => true)
        docs = []
        document_extractor.call(iter, docs) rescue StopIteration
        return docs
      end
    end

    def inspect
      %(#<#{self.class.name}:#{self.object_id} @endpoint=#{@endpoint.inspect} @params=#{@params.inspect}>)
    end
  end
end
