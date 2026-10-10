defmodule Rail.Issues.Utils.CalculateGithubOwner do
  @moduledoc """
  Who owns a GitHub issue in Rail, from its assignees.
  """

  @doc """
  GitHub drops an assignee it cannot take without a word, so Rail's `current` owner stays unless
  `assignee_user_ids`, the Rail users among GitHub's assignees, names somebody else.
  """
  def calculate_github_owner(current, assignee_user_ids) do
    if current && (assignee_user_ids == [] or current in assignee_user_ids),
      do: current,
      else: List.first(assignee_user_ids)
  end
end
