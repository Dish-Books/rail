defmodule RailWeb.QaController do
  @moduledoc """
  Serves the evidence a QA pass filed, out of its task's scratch.

  Two ways in, and neither lets a path come from the URL. `evidence/2` names a
  finding and a position in that finding's own evidence list, and the filename is
  whatever the row at that position holds. `shot/2` names a file, and it is
  served only if `Rail.Pipeline.list_qa_evidence/1` already listed it - so the
  name is matched against the directory rather than joined onto it, and the worst
  a caller can do with a made-up one is get a 404.

  There are two because a finding's evidence only exists once the pass has
  written its report, and the point of watching a pass is seeing what it saw
  while it is still going.

  An agent wrote every one of these, so none is served as what its name claims:
  what the file holds picks the type, and nothing is ever rendered as a page.
  """
  use RailWeb, :controller

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaEvidence
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  def evidence(conn, %{"task_id" => task_id, "key" => key, "index" => index}) do
    with {:ok, %Task{} = task} <- Pipeline.get_task(task_id),
         true <- Scope.can_access_project?(conn.assigns.current_scope, task.project_id),
         %QaEvidence{path: path} when is_binary(path) <- evidence(task, key, index),
         {:ok, kind} <- Pipeline.classify_qa_evidence(task, path) do
      send_shot(conn, Path.join([task.scratch_path, "qa", path]), kind)
    else
      _missing -> send_resp(conn, 404, "Not found")
    end
  end

  def shot(conn, %{"task_id" => task_id, "file" => file}) do
    with {:ok, %Task{} = task} <- Pipeline.get_task(task_id),
         true <- Scope.can_access_project?(conn.assigns.current_scope, task.project_id),
         %{file: listed, kind: kind} <- Enum.find(Pipeline.list_qa_evidence(task), &(&1.file == file)) do
      send_shot(conn, Path.join([task.scratch_path, "qa", "evidence", listed]), kind)
    else
      _missing -> send_resp(conn, 404, "Not found")
    end
  end

  defp send_shot(conn, file, kind) do
    conn
    |> served_as(kind, file)
    |> put_resp_header("x-content-type-options", "nosniff")
    # Filing again under the same check and caption replaces a file under the same
    # name, so a browser has to ask again rather than show the last pass.
    |> put_resp_header("cache-control", "private, no-cache")
    |> send_file(200, file)
  end

  defp served_as(conn, :screenshot, file), do: put_resp_content_type(conn, MIME.from_path(file))
  defp served_as(conn, :pdf, _file), do: put_resp_content_type(conn, "application/pdf", nil)
  defp served_as(conn, :text, _file), do: put_resp_content_type(conn, "text/plain")

  defp served_as(conn, :file, _file) do
    conn
    |> put_resp_content_type("application/octet-stream", nil)
    |> put_resp_header("content-disposition", "attachment")
  end

  defp evidence(%Task{} = task, key, index) do
    with {position, ""} <- Integer.parse(index),
         true <- position >= 0,
         %{evidence: evidence} <- Enum.find(Pipeline.list_qa_findings(task), &(&1.key == key)) do
      Enum.at(evidence, position)
    else
      _missing -> nil
    end
  end
end
