defmodule RailWeb.QaController do
  @moduledoc """
  Serves one piece of evidence a QA finding named, out of its task's scratch.

  The path never comes from the URL. A request names a finding and a position in
  that finding's own evidence list, and the filename is whatever the row at that
  position holds - so a request cannot ask for a file no finding mentions, and
  the worst a caller can do with a made-up key or index is get a 404. The report
  reader drops evidence whose path is not confined to the QA directory and the
  changeset refuses to store one, which is what makes the row safe to trust here.
  """
  use RailWeb, :controller

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaEvidence
  alias Rail.Pipeline.Schemas.Task

  def evidence(conn, %{"task_id" => task_id, "key" => key, "index" => index}) do
    with {:ok, %Task{} = task} <- Pipeline.get_task(task_id),
         %QaEvidence{path: path} when is_binary(path) <- evidence(task, key, index),
         file = Path.join([task.scratch_path, "qa", path]),
         true <- File.regular?(file) do
      conn
      |> put_resp_content_type(MIME.from_path(file))
      |> put_resp_header("cache-control", "private, max-age=31536000")
      |> send_file(200, file)
    else
      _missing -> send_resp(conn, 404, "Not found")
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
