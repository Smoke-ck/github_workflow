class SlackBlockkitComponent
  def initialize(deploy_information)
    @deploy_info_repos = deploy_information
  end


  def render
    {
      "blocks": [
        {
          "type": "rich_text",
          "elements": deploy_info_repos.map { |_, info| diff_section_component(repo_diff: info[:diff]) }
        }
      ]
    }
  end

  private

  attr_reader :deploy_info_repos

  def diff_section_component(repo_diff:)
    {
      "type": "rich_text_preformatted",
      "elements": [
        {
          "type": "text",
          "text": repo_diff
        }
      ]
    }
  end
end
