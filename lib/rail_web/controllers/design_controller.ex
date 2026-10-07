defmodule RailWeb.DesignController do
  @moduledoc """
  Serves a design option's page and screenshot out of its task's scratch.

  Only an option the designer's manifest names is served, so a key is never a
  path. The page is the agent's own HTML, so it is served sandboxed without
  Rail's origin: it can run the scripts a mockup needs and reach nothing of
  Rail's. Nothing is kept, so a revision is never shadowed by an earlier one.

  Rail's own frame asks with `comments=1`, which adds the overlay that comments on elements; Open never does.
  """
  use RailWeb, :controller

  alias Rail.Pipeline
  alias Rail.Scope

  def show(conn, %{"task_id" => task_id, "key" => key} = params) do
    case option(conn, task_id, key) do
      %{html: html} when is_binary(html) ->
        html = if params["comments"] == "1", do: html <> overlay_tag(), else: html

        conn
        |> put_resp_header("content-security-policy", "sandbox allow-scripts")
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)

      _missing ->
        send_resp(conn, 404, "Not found")
    end
  end

  def screenshot(conn, %{"task_id" => task_id, "key" => key}) do
    case option(conn, task_id, key) do
      %{screenshot_version: version, screenshot_path: path} when is_integer(version) ->
        conn
        |> put_resp_content_type("image/png")
        |> put_resp_header("cache-control", "private, no-cache")
        |> send_file(200, path)

      _missing ->
        send_resp(conn, 404, "Not found")
    end
  end

  # Loaded from Rail's origin like any CDN script a mockup uses, since the sandbox sets no script source.
  defp overlay_tag, do: ~s(<script src="#{~p"/assets/design_overlay.js"}" data-rail-overlay></script>\n)

  defp option(conn, task_id, key) do
    with {:ok, task} <- Pipeline.get_task(task_id),
         true <- Scope.can_access_project?(conn.assigns.current_scope, task.project_id),
         %{options: options} <- Pipeline.read_design(task) do
      Enum.find(options, &(&1.key == key))
    else
      _missing -> nil
    end
  end
end
