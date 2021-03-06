class GithubMetricsFetcher
  require 'rest-client'
  require 'json'
  require 'concurrent'
  require 'concurrent-edge'
  require 'concurrent/edge/throttle'

  attr_accessor :url
  attr_accessor :number
  attr_accessor :user
  attr_accessor :repo
  attr_accessor :commits

  SOURCES = Rails.configuration.github_sources 

  class << self
    def supports_url?(url)
      if ! url.nil?
        lower_case_url = url.downcase
        params = SOURCES.find { | params | ! params[:REGEX].match(lower_case_url).nil? }
        ! params.nil?
      else 
        false
      end
    end
  end

  def initialize(params)
    @url = params[:url]
    @loaded = false
    @commit_filter = params[:commit_filter].nil? ? lambda { |commit| true } : params[:commit_filter]
    @team_filter = params[:team_filter].nil? ? lambda { |email,login|  true } : params[:team_filter]
  end

  def is_loaded?
    @loaded
  end

  def fetch_content
    lower_case_url = @url.downcase
    params = SOURCES.find { | params | ! params[:REGEX].match(lower_case_url).nil? }

    if !params.nil?
      url_parsed = params[:REGEX].match(lower_case_url)
      @user = url_parsed['username']
      @repo = url_parsed['reponame']

      if url_parsed.names.include?('prnum')
        @number = url_parsed['prnum']
      end

      params[:throttle] = Concurrent::Throttle.new Rails.configuration.github_throttle

      @commits = self.send(params[:FUNCTION], params)
    end
    
    @loaded = true
  end

  def reduce_commits_to_user_stats 
    if ! @commits.nil? and ! @commits[:data].nil?
      default = {:count => 0, :total => 0}
      @commits[:data].reduce(Hash.new(default)) { | total, commit |
        oldrow = total[commit[:email]]
        newrow = { 
          :count => oldrow[:count] + 1, 
          :total => oldrow[:total] + commit[:stats][:total] }
        total.update(commit[:email] => newrow)
    }
    end
  end

  def to_bar_graph 
    data = reduce_commits_to_user_stats
    if ! data.nil? && ! data.empty?
      result = data.map { | k, v | [k, v[:total]]}
      result.unshift(["Name", "Total Changes"])
    else 
      ["Name", "Total Changes"]
    end
  end

  private

  def fetch_project_data(params)
    query = build_github_project_query(@user, @repo)

    RestClient.post(params[:GRAPHQL], query, :authorization => "Bearer #{params[:TOKEN]}") { |response, request, result|
      case response.code
      when 200
        json = JSON.parse(response.body)
        created_at = get_data(json, ["data", "repository", "createdAt"])
        is_fork = get_data(json, ["data", "repository", "isFork"])
        since = "since:\\\"#{created_at}\\\""

        fetch_project_commits_data(params, since)
      else
        { :error => "Error loading project #{response.code}", :msg => response.body }
      end
    }
  end

  def fetch_project_commits_data(params, since, page_info = {}, commits_list = Array.new)
    after_query = build_after_query(page_info) 
    query = build_github_project_commits_query(@user, @repo, since, after_query)

    RestClient.post(params[:GRAPHQL], query, :authorization => "Bearer #{params[:TOKEN]}") { |response, request, result|
      case response.code
      when 200
        json = JSON.parse(response.body)
        page_info = get_data(json, ["data", "repository", "ref", "target", "history", "pageInfo"])
        commits = get_data(json, ["data", "repository", "ref", "target", "history", "edges"])

        if commits.nil?
          return json
        end

        p = commits.map { | commit | 
          oid = get_data(commit, ["node", "oid"])
          login = get_data(commit, ["node", "author", "user", "login"])
          email = get_data(commit, ["node", "author", "email"])

          #puts "commit", @commit_filter.call(oid), "team", @team_filter.call(email, login)

          if @commit_filter.call(oid) && @team_filter.call(email, login)
            puts "loading #{oid}"
            params[:throttle].throttled_future(1) do 
              oid = get_data(commit, ["node", "oid"])
              name = get_data(commit, ["node", "author", "name"])
              date = get_data(commit, ["node", "committedDate"])
              stats = fetch_commit_stats_data(params, @user, @repo, oid)

              { :user_id => login,
              :commit_id => oid,
              :commit_date => date, 
              :user_name => name, 
              :user_email => email, 
              :lines_added => stats[:additions],
              :lines_deleted => stats[:deletions],
              :lines_changed => stats[:total]}
            end
          else
              Concurrent::Promises.fulfilled_future( nil )
          end
        }

        commits_list = commits_list + p

        if page_info["hasNextPage"] == "true"
          fetch_pr_data(params, page_info, commits_list) 
        else
          { :data => Concurrent::Promises.zip_futures(*commits_list).value!
              .select{ |t| ! t.nil? }
          }
        end
      else
        { :error => "Error loading commits list #{response.code}", :msg => response.body, :data => commits_list }
      end
    }
  end

  def fetch_pr_commits_data(params, page_info = {}, commits_list = Array.new)
    after_query = build_after_query(page_info) 
    query = build_github_pr_query(@user, @repo, @number, after_query)

    RestClient.post(params[:GRAPHQL], query, :authorization => "Bearer #{params[:TOKEN]}") { |response, request, result|
      case response.code
      when 200
        json = JSON.parse(response.body)
        pull_request = get_data(json, ["data", "repository", "pullRequest"])
        if ! pull_request.nil?
          page_info = get_data(pull_request, ["commits", "pageInfo"])
          commits = get_data(pull_request, ["commits", "nodes"])

          p = commits.map { | commit | 
            oid = get_data(commit, ["commit", "oid"])
            login = get_data(commit, ["commit", "author", "user", "login"])
            email = get_data(commit, ["commit", "author", "email"])
            
            if @commit_filter.call(oid) && @team_filter.call(email, login)
              params[:throttle].throttled_future(1) do
                name = get_data(commit, ["commit", "author", "name"])
                date = get_data(commit, ["commit", "committedDate"])
                stats = fetch_commit_stats_data(params, @user, @repo, oid)

                { :user_id => login,
                :commit_id => oid,
                :commit_date => date, 
                :user_name => name, 
                :user_email => email, 
                :lines_added => stats[:additions],
                :lines_deleted => stats[:deletions],
                :lines_changed => stats[:total] }
              end
            else
              Concurrent::Promises.fulfilled_future( nil )
            end
          } 

          commits_list = commits_list + p

          if page_info["hasNextPage"] == "true"
            fetch_pr_data(params, page_info, commits_list) 
          else
            { :data => Concurrent::Promises.zip_futures(*commits_list).value!
                .select{ |t| ! t.nil? }
            }
          end
        end
      else
        { :error => "Error loading commits list #{response.code}", :msg => response.body, :data => commits_list }
      end
    }
  end

  def fetch_commit_stats_data(params, user_name, repo_name, commit_hash) 
    query = "#{params[:API]}/#{user_name}/#{repo_name}/commits/#{commit_hash}"
    RestClient.get(
      query, 
      :authorization  => "Bearer #{params[:TOKEN]}") { | response, request, result|
      case response.code
      when 200
        json = JSON.parse(response.body)
        total = get_data(json, ["stats", "total"])
        additions = get_data(json, ["stats", "additions"])
        deletions = get_data(json, ["stats", "deletions"])
        { total: total, additions: additions, deletions: deletions}
      else
        { :error => "Error loading stats #{response.code}", :msg => response.body }
      end
    }
  end

  def build_after_query(page_info) 
    if page_info["hasNextPage"] == "true"
      "after:\\\"#{page_info.endCursor}\\\""
    else
      ""
    end
  end

  def build_github_pr_query(user_name, repo_name, pr_number, after_query = "")
    query = <<-EOS.gsub(/^[\s\t]*|[\s\t]*\n/, ' ') 
    query { 
      repository(
        name: \\\"#{repo_name}\\\", 
        owner: \\\"#{user_name}\\\") 
        { 
          pullRequest(number: #{pr_number})  
          { 
              number 
              commits(first: 100 #{after_query}) 
              { 
                nodes 
                { 
                  commit { 
                    oid commitUrl committedDate 
                    author
                    { 
                      date email name 
                      user {
                        login
                      }
                    } 
                } 
              }
              pageInfo {
                endCursor hasNextPage
              } 
            } 
          } 
        } 
      }
      EOS
    "{ \"query\" : \"#{query}\"}"
  end

  def build_github_project_query(user_name, repo_name)
    query = <<-EOS.gsub(/^[\s\t]*|[\s\t]*\n/, ' ')
    query { 
      repository(
        name: \\\"#{repo_name}\\\", 
        owner: \\\"#{user_name}\\\") 
        { 
          isFork
          createdAt
        }
    }
    EOS

    "{ \"query\" : \"#{query}\"}"
  end

  def build_github_project_commits_query(user_name, repo_name, since, after_query = "")
    query = <<-EOS.gsub(/^[\s\t]*|[\s\t]*\n/, ' ') 
    query { 
      repository(
        name: \\\"#{repo_name}\\\", 
        owner: \\\"#{user_name}\\\") 
        { 
          ref(qualifiedName: \\\"master\\\") {
            target {
              ... on Commit {
                id
                history(first: 100 #{since} #{after_query}) {
                  pageInfo {
                    endCursor hasNextPage
                  }
                  edges {
                    node {
                      oid commitUrl committedDate 
                      author
                      { 
                        date email name  
                        user {
                          login
                        }
                      }  
                    }
                  }
                }
              }
            }
          }
        } 
      }
      EOS
    
    "{ \"query\" : \"#{query}\"}"
  end

  def get_data(tree, array)
    pointer = tree

    for a in array
      if !pointer.nil? and pointer.has_key?(a)
        pointer = pointer.fetch(a)
      else
        pointer = nil
        break
      end
    end

    pointer
  end
end
