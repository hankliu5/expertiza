class TrelloLoaderAdaptee < MetricLoaderAdapter
	# Responses for using TrelloMetricsFetcher to fetch the metrics and stores them
	# to the database.
	SOURCES = Rails.configuration.trello_source


	def self.can_load?(params)
		# Helps to check the parameters can be used to load data by using TrelloMetricsFetcher.
		team, assignment, url = params.values_at(:team, :assignment, :url)
		tests = [!team.nil?, !assignment.nil?, !url.nil?, TrelloMetricsFetcher.supports_url?(url)]
		tests.inject(true){ |sum, a| sum && a }
	end

	def self.load_metric(params)
		# Loads the metrics by using TrelloMetricsFetcher and stores the data into db.
		team, assignment, url = params.values_at(:team, :assignment, :url)
		team_filter_lam = make_team_filter(team) # gets the user's information

		# gets previous information
		metric_db_data = Metric.includes(:metric_data_points).where(
			team_id: team.id,
			assignment_id: assignment.id,
			source: MetricDataPointType.sources[:trello],
			remote_id: url
		)

		metric_db_data = [] if metric_db_data.nil?
		metrics = TrelloMetricsFetcher.new({
			:url => url,
			:team_filter => team_filter_lam
			})

		metrics.fetch_content

		# stores newly fetched information to the database.
		new_metric = create_metric(team, assignment, metrics.board_id, metric_db_data.count + 1, metrics)
		return metric_db_data << new_metric
	end

	def self.create_metric(team, assignment, board_id, version, metrics)
		# creates a new metric for the fetched information
		new_metric = Metric.create(
			team_id: team.id,
			assignment_id: assignment.id,
			source: :trello,
			remote_id: :url,
			uri: "#{board_id}:#{version}"
		)
		create_points(new_metric, metrics)
		return new_metric
	end

	def self.create_points(new_metric, metrics)
		# Creates metric point and stores it to the database
		total_items = metrics.total_items
		checked_items = metrics.checked_items
		member_id_to_user_name = metrics.member_id_to_user_name
		member_id_to_count = metrics.member_id_to_count

		data_type = MetricDataPointType.where(
			:name => "total_items",
			:source => MetricDataPointType.sources[:trello]
		)
		if !data_type.empty?
			new_metric.metric_data_points.create(
				metric_data_point_type_id: data_type.first.id,
				value: total_items.to_s
			)
		end

		data_type = MetricDataPointType.where(
			:name => "checked_items",
			:source => MetricDataPointType.sources[:trello]
		)
		if !data_type.empty?
			new_metric.metric_data_points.create(
				metric_data_point_type_id: data_type.first.id,
				value: checked_items.to_s
			)
		end

		data_type = MetricDataPointType.where(
			:name => "users_contributions",
			:source => MetricDataPointType.sources[:trello]
		)
		result = ""
		if !data_type.empty?
			member_id_to_user_name.each do |id, name|
				result += "#{name},#{member_id_to_count[id]},"
			end

			new_metric.metric_data_points.create(
				metric_data_point_type_id: data_type.first.id,
				value: result[0...-1]
			)
		end
	end

	def self.make_team_filter(team)
		# Creates a lambda that checks current user is in the team.
		trello_names = team.users.map{ |u| u.trello_name }
		user_emails = team.users.map{ |u| u.email }

		lambda { |email, login| trello_names.include?(login) || user_emails.include?(email) }
	end

	def self.to_map(metric_data)
		# maps the metric data to a hash.
    metric_data.map{ |n|
      n.metric_data_points.map{ |m|
        [m.metric_data_point_type.name.to_sym, m.value]
      }.to_h
    }
	end

	def self.map_user_contributions(contribution_str)
		arr = contribution_str.split(",")
		result = {}
		arr.each_slice(2) { |user, count| result[user.to_sym] = count }
		return result
	end

	def self.displayAdapter(params)
		return true
	end
end
