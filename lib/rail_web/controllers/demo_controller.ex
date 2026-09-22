defmodule RailWeb.DemoController do
  @moduledoc """
  Serves the video a demo run recorded, out of its task's scratch.

  One file per task and Rail named it, so nothing here takes a path from the URL:
  the task id is looked up and the filename is a constant. The worst a caller can
  do with an id that is not a task is get a 404.

  Range requests are answered because a video element asks for them. A player
  handed the whole file plays it from the start and nothing else - no seeking, no
  jumping to the beat somebody clicked - and the beats are half the point of the
  panel.
  """
  use RailWeb, :controller

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  def video(conn, %{"task_id" => task_id}) do
    with {:ok, %Task{} = task} <- Pipeline.get_task(task_id),
         file = Path.join([task.scratch_path, "demo", "demo.webm"]),
         %File.Stat{size: size} <- stat(file) do
      send_video(conn, file, size)
    else
      _missing -> send_resp(conn, 404, "Not found")
    end
  end

  defp stat(file) do
    case File.stat(file) do
      {:ok, %File.Stat{type: :regular} = stat} -> stat
      _missing -> nil
    end
  end

  defp send_video(conn, file, size) do
    conn =
      conn
      |> put_resp_content_type("video/webm")
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("cache-control", "private, no-cache")

    case requested_range(get_req_header(conn, "range"), size) do
      {first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, file, first, last - first + 1)

      nil ->
        send_file(conn, 200, file)
    end
  end

  # Only the one form a video element actually sends: a single range, counted
  # from the start. Anything else is answered with the whole file, which is
  # always a correct answer to a range request even if it is not the best one.
  defp requested_range(["bytes=" <> requested], size) do
    case String.split(requested, "-") do
      [first, ""] -> bounded(first, size - 1, size)
      [first, last] -> bounded(first, last, size)
      _unreadable -> nil
    end
  end

  defp requested_range(_no_range, _size), do: nil

  defp bounded(first, last, size) do
    with {first, ""} <- Integer.parse(to_string(first)),
         {last, ""} <- Integer.parse(to_string(last)),
         true <- first >= 0 and first <= last and first < size do
      {first, min(last, size - 1)}
    else
      _unusable -> nil
    end
  end
end
