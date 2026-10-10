defmodule RailWeb.ScreenController do
  use RailWeb, :controller

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  # Named by the state's key alone, since a state has one picture, so the file served is one the listing
  # found and never a path from the URL.
  def show(conn, %{"task_id" => task_id, "key" => key}) do
    with {:ok, %Task{} = task} <- Pipeline.get_task(task_id),
         true <- Scope.can_access_project?(conn.assigns.current_scope, task.project_id),
         %{file: file} <- Enum.find(Pipeline.list_screens(task), &(&1.key == key)) do
      conn
      |> put_resp_content_type("image/jpeg", nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, no-cache")
      |> send_file(200, Path.join([task.scratch_path, "qa", file]))
    else
      _missing -> send_resp(conn, 404, "Not found")
    end
  end
end
