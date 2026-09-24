defmodule Rail.Git.Utils.CommitAuthor do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Returns who git acts as for `task`: the GitHub name and email of the person its
  ticket belongs to, with their signing key, or the Rail bot, unsigned.
  """
  def commit_author(%Task{} = task) do
    # Forced, because who the ticket is assigned to may have changed since
    # whatever loaded this task read it, and that is who the commit belongs to.
    task |> Repo.preload([issue: :owner_user], force: true) |> Map.fetch!(:issue) |> author()
  end

  defp author(%Issue{owner_user: %User{} = user}) do
    %{
      name: user.name || user.login,
      email: user.email,
      signing_key: user.signing_key,
      signing_public_key: user.signing_public_key
    }
  end

  defp author(%Issue{}) do
    config = Application.get_env(:rail, :git, [])

    %{
      name: Keyword.get(config, :bot_name, "Rail"),
      email: Keyword.get(config, :bot_email, "rail[bot]@railai.dev"),
      signing_key: nil,
      signing_public_key: nil
    }
  end
end
