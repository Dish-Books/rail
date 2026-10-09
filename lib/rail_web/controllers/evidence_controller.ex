defmodule RailWeb.EvidenceController do
  @moduledoc """
  Serves a file a finding attached, named by the finding's key and the piece's place, so no path comes from
  the URL; an agent wrote it, so its content picks the type, and nothing is rendered as a page.
  """
  use RailWeb, :controller

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  def show(conn, %{"task_id" => task_id, "key" => key, "index" => index}) do
    with {:ok, %Task{} = task} <- Pipeline.get_task(task_id),
         true <- Scope.can_access_project?(conn.assigns.current_scope, task.project_id),
         {:ok, %{file: file, kind: kind}} <- Pipeline.get_finding_evidence(task, key, index) do
      conn
      |> served_as(kind, file)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, no-cache")
      |> send_file(200, file)
    else
      _missing -> send_resp(conn, 404, "Not found")
    end
  end

  defp served_as(conn, :screenshot, file), do: put_resp_content_type(conn, MIME.from_path(file))
  defp served_as(conn, :pdf, _file), do: put_resp_content_type(conn, "application/pdf", nil)
  defp served_as(conn, :text, _file), do: put_resp_content_type(conn, "text/plain")

  defp served_as(conn, :file, _file) do
    conn
    |> put_resp_content_type("application/octet-stream", nil)
    |> put_resp_header("content-disposition", "attachment")
  end
end
