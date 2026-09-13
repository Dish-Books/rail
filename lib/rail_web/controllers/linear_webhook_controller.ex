defmodule RailWeb.LinearWebhookController do
  @moduledoc """
  Receives and processes incoming Linear webhooks with HMAC-SHA256 signature verification.
  """
  use RailWeb, :controller

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo

  def handle(conn, %{"workspace_id" => workspace_id} = params) do
    case find_workspace(workspace_id) do
      %LinearWorkspace{} = workspace ->
        raw_body = conn.assigns[:raw_body] || ""
        signature = get_signature(conn)

        if valid_signature?(raw_body, workspace.webhook_secret, signature) do
          process_event(workspace, params)
          json(conn, %{received: true})
        else
          conn
          |> put_status(:unauthorized)
          |> json(%{error: "Invalid signature"})
        end

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Workspace not found"})
    end
  end

  defp find_workspace(id) do
    Repo.get(LinearWorkspace, id) || Repo.get_by(LinearWorkspace, external_id: id)
  end

  defp get_signature(conn) do
    case get_req_header(conn, "linear-signature") do
      [sig | _tail] -> sig
      [] -> nil
    end
  end

  defp valid_signature?(body, secret, signature) when is_binary(secret) and is_binary(signature) do
    expected = :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)
    Plug.Crypto.secure_compare(expected, String.downcase(signature))
  end

  defp valid_signature?(_body, _secret, _sig), do: false

  defp process_event(workspace, %{"type" => "Issue", "action" => action, "data" => data})
       when action in ["create", "update"] and is_map(data) do
    case workspace.project_id do
      project_id when is_binary(project_id) -> upsert_issue(project_id, data)
      nil -> :ok
    end
  end

  defp process_event(_workspace, %{"type" => "Issue", "action" => "remove", "data" => %{"id" => external_id}})
       when is_binary(external_id) do
    case Repo.get_by(Issue, external_id: external_id) do
      %Issue{} = issue ->
        Repo.delete(issue)

      nil ->
        :ok
    end
  end

  defp process_event(_workspace, _params), do: :ok

  defp upsert_issue(project_id, data) do
    state_map = data["state"] || %{}

    attrs = %{
      project_id: project_id,
      external_id: data["id"],
      identifier: data["identifier"],
      title: data["title"],
      description: data["description"],
      state: map_state_type(state_map["type"]),
      state_name: state_map["name"],
      branch_name: data["branchName"],
      url: data["url"],
      linear_created_at: parse_datetime(data["createdAt"]),
      linear_updated_at: parse_datetime(data["updatedAt"])
    }

    case Repo.get_by(Issue, external_id: data["id"]) do
      %Issue{} = existing ->
        existing
        |> Issue.changeset(attrs)
        |> Repo.update()

      nil ->
        %Issue{}
        |> Issue.changeset(attrs)
        |> Repo.insert()
    end
  end

  defp map_state_type("triage"), do: :triage
  defp map_state_type("backlog"), do: :backlog
  defp map_state_type("unstarted"), do: :backlog
  defp map_state_type("started"), do: :in_progress
  defp map_state_type("completed"), do: :done
  defp map_state_type("canceled"), do: :canceled
  defp map_state_type(_other), do: :backlog

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _other -> nil
    end
  end
end
