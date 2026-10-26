defmodule RailWeb.DiffImageController do
  @moduledoc """
  Serves one side of a picture a task's diff changed: `old` as the diff's base had
  it, `new` as the worktree or the commit has it. `view` is the pane's, the whole
  branch when it is left out, `uncommitted`, or a commit's sha.
  """
  use RailWeb, :controller

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  def show(conn, %{"task_id" => task_id, "side" => side, "path" => path} = params) when side in ["old", "new"] do
    with {:ok, %Task{} = task} <- Pipeline.get_task(task_id),
         true <- Scope.can_access_project?(conn.assigns.current_scope, task.project_id),
         {:ok, type, bytes} <- Git.read_diff_image(task, path, String.to_existing_atom(side), view(params["view"])) do
      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, no-cache")
      |> send_resp(200, bytes)
    else
      _missing -> send_resp(conn, 404, "Not found")
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "Not found")

  defp view(nil), do: :branch
  defp view("uncommitted"), do: :uncommitted
  defp view(sha), do: {:commit, sha}
end
