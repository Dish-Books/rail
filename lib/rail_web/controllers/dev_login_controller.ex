defmodule RailWeb.DevLoginController do
  @moduledoc false

  use RailWeb, :controller

  alias Rail.Users
  alias Rail.Users.Schemas.User
  alias RailWeb.UserAuth

  @default_email "qa-admin@rail.local"

  def login(conn, params) do
    email = params["email"] || @default_email
    return_to = params["return_to"]

    conn =
      if return_to do
        put_session(conn, :user_return_to, return_to)
      else
        conn
      end

    case ensure_user(email) do
      {:ok, %User{} = user} ->
        UserAuth.log_in_user(conn, user)

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> text("Failed to sign in dev user")
    end
  end

  defp ensure_user(email) do
    case Users.get_user(email: email) do
      {:ok, %User{} = user} ->
        {:ok, user}

      {:error, :not_found} ->
        login = email |> String.split("@") |> List.first() || "qa-admin"
        github_id = "dev_#{:erlang.phash2(email)}"

        Users.register_oauth_user(%{
          email: email,
          login: login,
          name: "QA Admin",
          github_id: github_id,
          admin: true
        })
    end
  end
end
