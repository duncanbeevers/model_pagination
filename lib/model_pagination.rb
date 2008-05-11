# Extends a model or association with pagination capabilities. In addition to using the conventional
# finders, model pagination allows you to return pages at a time, as well as the number of pages the
# model or association has.
#
# In a model:
#   class Entry < ActiveRecord::Base; end
#
#   Entry.page(1)                              # Return the first page.
#   Entry.page(1, :order => 'created_at DESC') # Return the first page with an explicit order.
#   Entry.per_page = 15 # set the number of results to be returned per-page with the pagination methods
#   Entry.page_count                           # Return the number of pages in the collection
#   Entry.page_for_entry                       # Return the page number a given entry number would be on
#                                                 For example, Entry.page_for_entry(21) returns 2
#
# In an association:
#   class Workspace < ActiveRecord::Base
#     has_many :entries,
#       :order  => 'created_at DESC'
#   end
#
#   Workspace.find(1).entries.page(1)          # Returns the first 20 entries for the first workspace.
module ModelPagination  # :nodoc:
  module ActiveRecord
    def self.included mod # :nodoc:
      mod.extend ClassMethods
    end

    module ClassMethods
      # The number of entries per page the model or association returns.
      def per_page
        @per_page ||= 20
      end

      # Used to override the number of entries-per-page the model or association returns.
      def per_page= v
        @per_page = v
      end

      # The number of pages for this model or association.
      def page_count options = {}
        num = case
        when options.blank?
          count
        when options.kind_of?(Hash)
          count :all, options.block(:order, :limit, :offset)
        when options.kind_of?(String)
          count options
        when options.kind_of?(Fixnum)
          options
        end
        num.divmod(per_page).inject { |m,n| n > 0 ? m + 1 : m }
      end

      def page_for_entry entry_number
        entry_number.divmod(per_page).inject { |m,n| n > 0 ? m + 1 : m }
      end

      def page_options num, options = {}
        num = [ num.to_i, 1 ].max

        offset = (num - 1) * per_page

        options.merge(:limit => per_page, :offset => offset )
      end

      # Returns the requested page, applying the provided options.
      #   workspace.entries.page 1
      #   workspace.entries.page 1, :order => 'created_at ASC'
      named_scope :page, (Proc.new do |num, options|
        page_options [ num.to_i, 1 ].max, options
      end)

      # Step through and instantiate each member of the class and execute on it,
      #   but instantiate no more than per_page instances at any given time.
      # Safe for destructive actions or actions that modify the fields
      # your :order or :conditions clauses operate on.
      def each_by_page options = {}, &block
        by_page(options) do |page|
          page.each &block
        end
      end

      def by_page options = {}, &block
        # By-id for model-modifying blocks
        # Build SQL to get ids of all matching records using the options provided by the user
        sql = construct_finder_sql(options.merge( :select => 'id' ))
        # Get the results as an array of tiny hashes { "id" => "1" } and flatten them out to just the ids
        all_ids = connection.select_all(sql).map { |h| h['id'] }

        return unless all_ids.size > 0
        at_a_time = 0..(per_page-1)

        # chop apart the all_ids array a segment at a time
        begin
          ids = all_ids.slice!(at_a_time)
          ids_cases = []
          ids.each_with_index { |id, i| ids_cases << "WHEN #{id} THEN #{i}" }
          ids_cases = ids_cases.join(' ')

          # Do the deed on this page of results
          block.call(find(:all, options.merge(
            :conditions => [ 'id IN (?)', ids ],
            :order => "CASE id #{ids_cases} END"
          )))

        end until all_ids.empty?
      end

    end
  end

  module PaginationHelper
    # A "Just Works (tm)" pagination helper to accompany model pagination.
    # Defaults to looking in +@num_pages+ for the page count but can be overriden (see below).
    # Accepts the following optionss
    # :page_param => The param modified for each page link, indicating what page in the collection the link is to.
    # :partial => the partial file name to render out the pagination links, default is 'shared/pagination_links
    # :min_leading_pages => This many pages will always show up at the beginning of the pagination links, defaults to 3
    # :min_trailing_pages => This many pages will always show up at the end of the pagination links, defaults to 3
    # :range_about_current_page => This many pages will always show up to the left or right of the current page, defaults to 3
    # :num_pages => number of pages; will look in @num_pages if this is not passed in
    # :skip_params => array of param names to strip out of params so they won't show up in the url
    #
    # In the pagination links partial, you will be provided 3 locals
    # pages => an array containing integers and symbols (:ellipse)
    # current_page => an integer, element of pages array
    # options => the options passed to the pagination_links helper
    #
    def pagination_links original_options = {}
      skip_params = original_options.delete(:skip_params)
      block_params = ['action', 'controller'] + (skip_params || [])
      options = params.block(*block_params).merge(original_options).symbolize_keys

      min_leading_pages = (options.delete(:min_leading_pages) || 2).to_i
      min_trailing_pages = (options.delete(:min_trailing_pages) || 2).to_i
      range_about_current_page = (options.delete(:range_about_current_page) || 3).to_i
      page_param = (options.delete(:page_param) || :page).to_sym
      current_page = (options.delete(page_param) || 1).to_i
      partial = (options.delete(:partial) || 'shared/pagination_links')
      num_pages = (options.delete(:num_pages) || @num_pages)

      # In these cases, the pagination links are not interesting.
      return nil if num_pages.nil? || num_pages == 0 || num_pages == 1

      range    = (1..num_pages).to_a
      first    = range[0..(min_leading_pages - 1)]

      close_begin = [ 0, (current_page - (range_about_current_page + 1)) ].max
      close_end = [ (current_page + (range_about_current_page - 1)), num_pages - 1 ].min
      close    = range[close_begin..close_end] || []
      last     = range[-(min_trailing_pages)..-1] || []
      pages = (first + close + last).uniq.inject([]) { |m,n|
        if (m.last.to_i + 1) == n
          m << n
        else
          m << :ellipse << n
        end
        m
      }

      render(:partial => partial,
        :locals => {
          :pages        => pages,
          :page_param   => page_param,
          :current_page => current_page,
          :options      => options
        })
    end

  end

end

ActiveRecord::Base.send :include, ModelPagination::ActiveRecord
ActionController::Base.send :helper, ModelPagination::PaginationHelper
