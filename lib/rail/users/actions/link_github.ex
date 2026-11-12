defmodule Rail.Users.Actions.LinkGitHub do
  @moduledoc """
  Connects the scope's user to the GitHub account they just authorized, from Connected accounts.
  """

  import Ecto.Query
  import Rail.Users.Utils.OAuthAttrs

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Writes the GitHub profile and tokens onto the scope's user, keeping their email. Linking the account they
  already have refreshes its tokens. Refuses an account another user holds, returning that user, and a
  second account on a user who has one, returning them as they are, changing nothing either way.
  """
  def link_github(%Scope{user: %User{id: user_id}}, %Ueberauth.Auth{} = auth) do
    %{github_id: github_id} = attrs = auth |> oauth_attrs() |> Map.delete(:email)

    linked =
      Repo.transaction(fn ->
        user = Repo.one!(from u in User, where: u.id == ^user_id, lock: "FOR UPDATE")
        holder = github_id && Repo.get_by(User, github_id: github_id)

        cond do
          holder && holder.id != user.id -> Repo.rollback({:github_taken, holder})
          user.github_id && user.github_id != github_id -> Repo.rollback({:github_already_linked, user})
          true -> write(user, attrs)
        end
      end)

    with {:ok, user} <- linked do
      Phoenix.PubSub.broadcast(Rail.PubSub, "users", {:users_changed, user.id})
      {:ok, user}
    end
  end

  defp write(%User{} = user, attrs) do
    case user |> User.github_changeset(attrs) |> Repo.update() do
      {:ok, user} -> user
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
