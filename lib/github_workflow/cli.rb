require "rubygems"
require "pry"
require "faraday"
require "thor"
require "open3"
require "json"
require "terminal-table"
require "trello"

module GithubWorkflow
  class Cli < Thor
    PROCEED_TEXT = "Proceed? [y,yes]: ".freeze

    GITHUB_CONFIG = <<~TEXT
      {
        "oauth_token":              "TOKEN",
        "user_and_repo":            "ORG/REPO",
        "trello_key":               "KEY",
        "trello_token":             "TOKEN",
        "trello_board_id":          "BOARD_ID",
        "trello_platform_board_id": "BOARD_ID"
      }
    TEXT

    include Thor::Actions

    default_task :trello

    desc "trello", "Create issue from card"
    method_option :card_number, aliases: "-i", type: :string, required: true
    def trello
      ensure_github_config_present
      init_trello
      set_trello_card(type: nil)
      create_issue_from_trello_card
      stash
      rebase_main
      create_branch
      stash_pop
    end

    desc "platform", "Create issue from card"
    method_option :card_number, aliases: "-i", type: :string, required: true
    def platform
      ensure_github_config_present
      init_trello
      set_trello_card(type: :platform)
      create_issue_from_trello_card
      stash
      rebase_main
      create_branch
      stash_pop
    end

    desc "start", "Create branch named with issue number and issue title"
    method_option :issue_id, aliases: "-i", type: :string, required: true
    def start
      ensure_github_config_present
      stash
      rebase_main
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
      response = JSON.parse(github_client.get("repos/#{user_and_repo}/statuses/#{current_branch}").body)

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
      puts get_issue(issue_number_from_branch)["body"]
    end

    desc "open", "Open issue or PR in browser"
    def open
      ensure_github_config_present
      response = JSON.parse(github_client.get("repos/#{user_and_repo}/issues/#{issue_number_from_branch}").body)
      `/usr/bin/open -a "/Applications/Google Chrome.app" '#{response["html_url"]}'`
    end

    desc "create_and_start", "Create and start issue"
    method_option :name, aliases: "-m", type: :string, required: true
    def create_and_start
      ensure_github_config_present
      create_issue
    end

    desc "cleanup", "Remove merged PR branches"
    def cleanup
      say_info("Checking merge status")
      merged_pr_branches
      puts "\n"

      if merged_pr_branches.any?
        say_info("Are you sure you want to delete the branches with checkmarks?")

        if yes?(PROCEED_TEXT)
          pass("Deleting Branches")

          merged_pr_branches.each do |branch|
            `git branch -D #{branch}`
          end
        else
          failure("Cleanup aborted")
        end
      else
        failure("No merged branches to delete")
      end
    end

    desc "reviews", "Displays count of requested reviews for each user"
    def reviews
      ensure_github_config_present
      reviewers = get_prs_list.map { |pr| pr["requested_reviewers"].map { |r| r["login"] } }.flatten
      reviewer_counts = reviewers.group_by { |i| i }.map { |k, v| [k, v.count] }

      if reviewer_counts.any?
        table = Terminal::Table.new(style: { width: 50 }) do |table_rows|
          table_rows << ["Username", "Requested PRs Count"]
          table_rows << :separator
          reviewer_counts.each { |reviewer_count| table_rows << reviewer_count }
        end

        puts table
      end
    end

    desc "deploy_notes", "Generate Deploy notes for a range of commits"
    method_option :commit_range, aliases: "-r", type: :string, required: true

    def deploy_notes
      puts formatted_deploy_notes
    end

    no_tasks do
      def get_issue(id)
        JSON.parse(github_client.get("repos/#{user_and_repo}/issues/#{id}").body)
      end

      def get_pr(id)
        JSON.parse(github_client.get("repos/#{user_and_repo}/pulls/#{id}").body)
      end

      def get_prs_list
        JSON.parse(github_client.get("repos/#{user_and_repo}/pulls&per_page=100").body)
      end

      def create_branch
        `git checkout -b #{branch_name_for_issue_number} main`
      end

      def ensure_origin_exists
        Open3.capture2("git rev-parse --abbrev-ref --symbolic-full-name @{u}").tap do |_, status|
          unless status.success?
            failure("Upstream branch does not exist. Please set before creating pull request. E.g., `git push -u origin branch_name`")
          end
        end
      end

      def create_issue_from_trello_card
        say_info("Creating issue")

        issue_params = {
          title: trello_card.name,
          body: issue_body_from_trello_card,
          assignees: [current_github_username],
          labels: trello_card.labels.map(&:name)
        }

        response = JSON.parse(github_client.post("repos/#{user_and_repo}/issues", issue_params.to_json).body)

        @issue_id = response["number"]

        github_client.post("/repos/#{user_and_repo}/issues/#{@issue_id}/comments", { body: trello_card.short_url }.to_json)
        trello_card.add_attachment response["html_url"]
      end

      def issue_body_from_trello_card
        [trello_card.desc, trello_deploy_note, trello_product_review_type, trello_pm].compact.join("\n\n")
      end

      def trello_pm
        custom_field = trello_card.custom_field_items.detect { |cfi| cfi.custom_field.name == "PM" }

        if custom_field.present?
          "**Responsible:** #{custom_field.option_value['text']}"
        end
      end

      def trello_deploy_note
        custom_field = trello_card.custom_field_items.detect { |cfi| cfi.custom_field.name == "Deploy Note" }

        if custom_field.present?
          "**Deploy Note:** #{custom_field.value['text']}"
        end
      end

      def trello_product_review_type
        custom_field = trello_card.custom_field_items.detect { |cfi| cfi.custom_field.name == "Product Review" }

        if custom_field.present?
          "**Product Review:** #{custom_field.option_value['text']}"
        end
      end

      def current_github_username
        JSON.parse(github_client.get("user").body)["login"]
      end

      def set_trello_card(type:)
        say_info("Fetching trello card")

        trello_board =
          if type
            Trello::Board.find(project_config["trello_#{type}_board_id"])
          else
            Trello::Board.find(project_config["trello_board_id"])
          end

        @trello_card = trello_board.find_card(options["card_number"].to_i)
      end

      def trello_card
        @trello_card
      end

      def ensure_github_config_present
        if project_config.nil? || (JSON.parse(GITHUB_CONFIG).keys - project_config.keys).any?
          failure("Please add `.github_workflow` file containing:\n#{GITHUB_CONFIG}")
        end
      end

      def init_trello
        Trello.configure do |config|
          config.developer_public_key = project_config["trello_key"]
          config.member_token = project_config["trello_token"]
        end
      end

      def project_config
        @project_config ||= JSON.parse(File.read(".github_workflow")) rescue nil
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
          "repos/#{user_and_repo}/issues",
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
          "repos/#{user_and_repo}/pulls",
          JSON.generate(
            {
              head: current_branch,
              base: options[:base_branch] || "main",
              issue: issue_number_from_branch.to_i
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
        issue = JSON.parse(github_client.get("repos/#{user_and_repo}/issues/#{issue_id}").body)
        "#{issue['number']}_#{issue['title'].strip.downcase.gsub(/[^a-zA-Z0-9]/, '_').squeeze("_")}"
      end

      def github_client
        Faraday.new(url: "https://api.github.com") do |faraday|
          faraday.request   :url_encoded
          faraday.adapter   Faraday.default_adapter
          faraday.authorization :Bearer, oauth_token
        end
      end

      def rebase_main
        say_info("Fetching changes and rebasing main")

        if success?("git pull origin main:main --rebase")
          pass("Fetched and rebased")
        else
          failure("Failed to fetch or rebase")
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

      def merged_pr_branches
        @merged_pr_branches ||=
          pr_branches.map do |branch|
            id = branch.split("_")[0].to_i
            merged = !!get_pr(id)["merged"]
            print merged ? "✅ " : "❌ "
            puts " #{branch}"
            merged ? branch : nil
          end.compact
      end

      def pr_branches
        `git branch`.gsub(" ", "").split("\n").select { |br| br.match /^[0-9]/ }
      end

      def commits_for_range
        JSON.parse(github_client.get("repos/#{user_and_repo}/compare/#{options[:commit_range]}").body)
      end

      def pull_request_in_commit_range
        pr_ids = commits_for_range["commits"].map do |commit|
          commit.dig("commit", "message").to_s.match(/(?<=\[#)\d{4,5}(?=\])/).to_s.to_i
        end.uniq.compact

        prs = pr_ids.map do |id|
          say_info("Fetching Pull Request ##{id}")
          pr = github_client.get("repos/#{user_and_repo}/pulls/#{id}")

          if pr.status == 404
            JSON.parse(github_client.get("repos/#{user_and_repo}/issues/#{id}").body)
          else
            JSON.parse(pr.body)
          end
        end
      end

      def formatted_deploy_notes
        pull_request_in_commit_range.map do |pr|
          deploy_note = pr["body"].to_s.split("**Deploy Note:**")[1].to_s.split(/\n/)[0].to_s

          if deploy_note.length > 0
            "- #{deploy_note}"
          else
            %Q{Missing deploy note: #{pr["title"]}}
          end
        end.unshift("[DaisyBill]")
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
