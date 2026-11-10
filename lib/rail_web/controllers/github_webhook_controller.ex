defmodule RailWeb.GithubWebhookController do
  @moduledoc """
  Receives the GitHub App's webhooks: checks the HMAC-SHA256 signature against the App's webhook
  secret, finds the project for the payload's repository and installation, and hands a genuine event
  to `Rail.Issues`: every one for a GitHub-tracked project, only `pull_request` for a Rail-tracked one.
  """
  use RailWeb, :controller

  alias Rail.Issues
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project

  def handle(conn, params) do
    if valid_signature?(conn),
      do: handle_event(conn, params),
      else: conn |> put_status(:unauthorized) |> json(%{error: "Invalid signature"})
  end

  # A delivery for a repository Rail does not track is answered as received, so GitHub does not
  # count it a failure.
  defp handle_event(conn, params) do
    repo = get_in(params, ["repository", "full_name"]) || ""
    event = List.first(get_req_header(conn, "x-github-event"))

    # A Rail-tracked repository's GitHub issues are never mirrored, but its merged pull requests finish tickets.
    with {:ok, %Project{tracker: tracker} = project}
         when tracker == :github or (tracker == :local and event == "pull_request") <-
           Projects.get_project(github_repo: repo),
         true <- get_in(params, ["installation", "id"]) == project.github_installation_id do
      Issues.handle_github_webhook(project, event, params)
      json(conn, %{received: true})
    else
      _not_ours -> json(conn, %{ignored: true})
    end
  end

  defp valid_signature?(conn) do
    secret = Application.get_env(:rail, :github, [])[:webhook_secret]

    case get_req_header(conn, "x-hub-signature-256") do
      ["sha256=" <> signature | _rest] when is_binary(secret) and secret != "" ->
        expected = :hmac |> :crypto.mac(:sha256, secret, conn.assigns[:raw_body] || "") |> Base.encode16(case: :lower)
        Plug.Crypto.secure_compare(expected, String.downcase(signature))

      _unsigned_or_no_secret ->
        false
    end
  end
end
