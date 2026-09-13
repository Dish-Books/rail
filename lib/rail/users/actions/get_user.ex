defmodule Rail.Users.Actions.GetUser do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Users.Schemas.User

  def get_user(by) when is_list(by) do
    case Repo.get_by(User, by) do
      %User{} = user -> {:ok, user}
      _nil -> {:error, :not_found}
    end
  end
end
