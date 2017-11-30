class TrelloMetricsFetcher
  require 'trello'
  require 'json'
  require 'concurrent'
  require 'concurrent-edge'
  require 'concurrent/edge/throttle'

  attr_accessor :url
	attr_accessor :board_id
  attr_accessor :member_id_to_count
  attr_accessor :member_id_to_user_name
  attr_accessor :checked_items
  attr_accessor :total_items

  SOURCE = Rails.configuration.trello_source

  class << self
    def supports_url?(url)
      if !url.nil?
        params = SOURCE[:REGEX].match(url)
        !params.nil?
      else
        false
      end
    end
  end

  def initialize(params)
    @url = params[:url]
		@team_filter = params[:team_filter].nil? ? lambda { |email,login| true } : params[:team_filter]
    @loaded = false
		Trello.configure do |config|
		  config.developer_public_key = SOURCE[:KEY] # The "key" from step 1
		  config.member_token = SOURCE[:TOKEN] # The token from step 2.
		end
  end

	def fetch_content
		params = SOURCE[:REGEX].match(@url)
		if !params.nil?
      @board_id = params['board_id']
			@board = Trello::Board.find(@board_id)
			@member_id_to_user_name = {}
			@member_id_to_count = {}
			@board.members.each do |member|
				member_id_to_user_name[member.id] = member.username
				member_id_to_count[member.id] = 0
			end

			@total_items = 0
			@checked_items = 0

			@board.cards.each do |card|
				card.checklists.each do |checklist|
					checklist.check_items.each do |item|
						@total_items += 1
						@checked_items += 1 if item["state"] == "complete"
					end
				end
			end

			@board.actions.each do |action|
				if action.type == "updateCheckItemStateOnCard" && action.data["checkItem"]["state"] == "complete"
					member_id_to_count[action.member_creator_id] += 1
				end
			end
		end
    @loaded = true
	end

  def is_loaded?
    @loaded
  end
end
