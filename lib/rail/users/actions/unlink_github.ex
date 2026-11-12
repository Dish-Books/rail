defmodule Rail.Users.Actions.UnlinkGitHub do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @doc """
  Forgets the scope's user's GitHub account, tokens and signing key, leaving them signed in to Rail.
  """
  def unlink_github(%Scope{user: %User{id: id}}) do
    # Read afresh, since another tab may have set up a signing key since this page's scope was built.
    user = Repo.get!(User, id)
    # Disconnect never waits on GitHub: a key it could not delete is unusable once Rail forgets the private half.
    _deleted_or_not = Users.delete_signing_key(Scope.for_user(user))

    with {:ok, user} <-
           user
           |> User.changeset(%{
             signing_key: nil,
             signing_public_key: nil,
             signing_key_github_id: nil,
             github_id: nil,
             login: nil,
             avatar_url: nil,
             github_token: nil,
             github_refresh_token: nil,
             github_token_expires_at: nil
           })
           |> Repo.update() do
      Phoenix.PubSub.broadcast(Rail.PubSub, "users", {:users_changed, user.id})
      {:ok, user}
    end
  end
end
