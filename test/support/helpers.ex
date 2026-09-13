defmodule RailTest.Helpers do
  @moduledoc false

  defdelegate create_temp_git_repo(opts \\ []), to: RailTest.GitHelpers
  defdelegate git!(dir, args), to: RailTest.GitHelpers

  @doc """
  Puts a session token for `user` on `conn` so requests are authenticated.
  """
  def log_in_user(conn, user) do
    token = Rail.Users.generate_user_session_token(user)

    conn
    |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
