defmodule RailWeb.QaController do
  @moduledoc """
  Serves the pictures a QA pass took, out of its task's scratch.

  Two ways in, and neither lets a path come from the URL. `evidence/2` names a
  finding and a position in that finding's own evidence list, and the filename is
  whatever the row at that position holds. `shot/2` names a file, and it is
  served only if `Rail.Pipeline.list_qa_evidence/1` already listed it - so the
  name is matched against the directory rather than joined onto it, and the worst
  a caller can do with a made-up one is get a 404.

  There are two because a finding's evidence only exists once the pass has
  written its report, and the point of watching a pass is seeing what it saw
  while it is still going.
  """
  use RailWeb, :controller

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaEvidence
  alias Rail.Pipeline.Schemas.Task

  def evidence(conn, %{"task_id" => task_id, "key" => key, "index" => index}) do
    with {:ok, %Task{} = task} <- Pipeline.get_task(task_id),
         %QaEvidence{path: path} when is_binary(path) <- evidence(task, key, index) do
      file = Path.join([task.scratch_path, "qa", path])
      send_shot(conn, file)
    else
      _missing -> send_resp(conn, 404, "Not found")
    end
  end

  def shot(conn, %{"task_id" => task_id, "file" => file}) do
    with {:ok, %Task{} = task} <- Pipeline.get_task(task_id),
         %{file: listed} <- Enum.find(Pipeline.list_qa_evidence(task), &(&1.file == file)) do
      send_shot(conn, Path.join([task.scratch_path, "qa", "evidence", listed]))
    else
      _missing -> send_resp(conn, 404, "Not found")
    end
  end

  defp send_shot(conn, file) do
    if File.regular?(file) do
      conn
      |> put_resp_content_type(MIME.from_path(file))
      |> put_resp_header("cache-control", "private, max-age=31536000")
      |> send_file(200, file)
    else
      send_resp(conn, 404, "Not found")
    end
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
