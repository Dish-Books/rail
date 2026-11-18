defmodule RailWeb.AttachmentController do
  use RailWeb, :controller

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  # Only a name in the shape a sent message writes, so no path reaches outside the task's attachments folder.
  @name ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(png|jpg|jpeg|gif|webp)\z/
  @types %{
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "jpeg" => "image/jpeg",
    "gif" => "image/gif",
    "webp" => "image/webp"
  }

  def show(conn, %{"task_id" => task_id, "name" => name}) do
    with [_name, extension] <- Regex.run(@name, name),
         {:ok, %Task{} = task} <- Pipeline.get_task(task_id),
         true <- Scope.can_access_project?(conn.assigns.current_scope, task.project_id),
         path = Path.join([task.scratch_path, "attachments", name]),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type(@types[extension], nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "sandbox")
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> send_file(200, path)
    else
      _missing -> send_resp(conn, 404, "Not found")
    end
  end
end
