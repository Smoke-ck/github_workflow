require "rubygems"
require "faraday"
require "thor"
require "open3"
require "json"
require "terminal-table"

module GithubWorkflow
  class Cli < Thor
    include Thor::Actions

    default_task :start

    desc "start", "Create branch named with issue number and issue title"
    method_option :issue_id, aliases: "-i", type: :string, required: true

    def start
      ensure_github_config_present
      stash
      checkout_master
      rebase_master
      create_branch
      stash_pop
    end

    desc "create_pr", "Convert Issue to Pull Request"

    method_option :base_branch, aliases: "-b", type: :string

    def create_pr
      ensure_github_config_present
      ensure_origin_exists
      convert_issue_to_pr
    end

    desc "push_and_pr", "Push branch to origin and convert Issue to Pull Request"

    method_option :base_branch, aliases: "-b", type: :string

    def push_and_pr
      ensure_github_config_present
      push_and_set_upstream
      convert_issue_to_pr
    end

    desc "status", "Check PR CI status"

    def status
      ensure_github_config_present
      ensure_origin_exists
      response = JSON.parse(github_client.get("repos/#{user_and_repo}/statuses/#{current_branch}?access_token=#{oauth_token}").body)

      if response.empty?
        alert "No statuses yet.  Have you pushed your branch?"
      else
        table = Terminal::Table.new(style: { width: 80 }) do |table_rows|
          table_rows << %w(CI Status Description)
          table_rows << :separator

          response.map { |status| status["context"] }.uniq.map do |status|
            response.select { |st| st["context"] == status }.sort_by { |st| st["updated_at"] }.last
          end.each do |status|
            table_rows << %w(context state description).map { |key| status[key] }
          end
        end

        puts table
      end
    end

    desc "info", "Print out issue description"

    def info
      ensure_github_config_present
      response = JSON.parse(github_client.get("repos/#{user_and_repo}/issues/#{issue_number_from_branch}?access_token=#{oauth_token}").body)
      puts response["body"]
    end

    desc "open", "Open issue or PR in browser"

    def open
      ensure_github_config_present
      response = JSON.parse(github_client.get("repos/#{user_and_repo}/issues/#{issue_number_from_branch}?access_token=#{oauth_token}").body)
      `/usr/bin/open -a "/Applications/Google Chrome.app" '#{response["html_url"]}'`
    end

    desc "create_and_start", "Create and start issue"

    method_option :name, aliases: "-m", type: :string, required: true

    def create_and_start
      ensure_github_config_present
      create_issue
    end

    no_tasks do
      def create_branch
        `git checkout -b #{branch_name_for_issue_number}`
      end

      def ensure_origin_exists
        Open3.capture2("git rev-parse --abbrev-ref --symbolic-full-name @{u}").tap do |_, status|
          unless status.success?
            failure("Upstream branch does not exist. Please set before creating pull request. E.g., `git push -u origin branch_name`")
          end
        end
      end

      def ensure_github_config_present
        unless project_config && project_config["oauth_token"] && project_config["user_and_repo"]
          failure('Please add `.github` file containing `{ "oauth_token": "TOKEN", "user_and_repo": "user/repo" }`')
        end
      end

      def project_config
        @project_config ||= JSON.parse(File.read(".github")) rescue nil
      end

      def oauth_token
        project_config["oauth_token"]
      end

      def user_and_repo
        project_config["user_and_repo"]
      end

      def push_and_set_upstream
        `git rev-parse --abbrev-ref HEAD | xargs git push origin -u`
      end

      def create_issue
        github_client.post(
          "repos/#{user_and_repo}/issues?access_token=#{oauth_token}",
          JSON.generate(
            {
              title: options[:name]
            }
          )
        ).tap do |response|
          if response.success?
            pass("Issue created")
            @issue_id = JSON.parse(response.body)["number"]
            start
          else
            alert("An error occurred when creating issue:")
            alert("#{response.status}: #{JSON.parse(response.body)['message']}")
          end
        end
      end

      def issue_id
        @issue_id ||= options[:issue_id]
      end

      def convert_issue_to_pr
        github_client.post(
          "repos/#{user_and_repo}/pulls?access_token=#{oauth_token}",
          JSON.generate(
            {
              head: current_branch,
              base: options[:base_branch] || "master",
              issue: issue_number_from_branch
            }
          )
        ).tap do |response|
          if response.success?
            pass("Issue converted to Pull Request")
            say_info(JSON.parse(response.body)["url"])
          else
            alert("An error occurred when creating PR:")
            alert("#{response.status}: #{JSON.parse(response.body)['message']}")
          end
        end
      end

      def issue_number_from_branch
        current_branch.split("_").first.tap do |issue_number|
          if !issue_number
            failure("Unable to parse issue number from branch. Are you sure you have a branch checked out?")
          end
        end
      end

      def current_branch
        `git rev-parse --abbrev-ref HEAD`.chomp
      end

      def branch_name_for_issue_number
        issue = JSON.parse(github_client.get("repos/#{user_and_repo}/issues/#{issue_id}?access_token=#{oauth_token}").body)
        "#{issue['number']}_#{issue['title'].strip.downcase.gsub(/[^a-zA-Z0-9]/, '_').squeeze("_")}"
      end

      def github_client
        Faraday.new(url: "https://api.github.com") do |faraday|
          faraday.request   :url_encoded
          faraday.adapter   Faraday.default_adapter
        end
      end

      def rebase_master
        say_info("Fetching changes and rebasing master")

        if success?("git pull --rebase")
          pass("Fetched and rebased")
        else
          failure("Failed to fetch or rebase")
        end
      end

      def checkout_master
        say_info("Checking out master")

        if success?("git checkout master")
          pass("Checked out master")
        else
          failure("Failed to checkout master")
        end
      end

      def stash
        `git diff --quiet`

        if !$?.success?
          say_info("Stashing local changes")
          `git stash --quiet`
          @stashed = true
        end
      end

      def stash_pop
        if @stashed
          say_info("Stash pop")
          `git stash pop --quiet`
        end
      end

      def success?(command)
        IO.popen(command) do |output|
          output.each { |line| puts line }
        end

        $?.success?
      end

      def alert(message)
        say_status("ALERT", message, :red)
      end

      def say_info(message)
        say_status("INFO", message, :black)
      end

      def pass(message)
        say_status("OK", message, :green)
      end

      def failure(message)
        say_status("FAIL", message, :red)
        exit
      end
    end
  end
end
