defmodule RailWeb.DesignController do
  @moduledoc """
  Serves a design option's page and screenshot out of its task's scratch.

  Only an option the designer's manifest names is served, so a key is never a
  path. The page is the agent's own HTML, so it is served sandboxed without
  Rail's origin: it can run the scripts a mockup needs and reach nothing of
  Rail's.
  """
  use RailWeb, :controller

  alias Rail.Pipeline

  def show(conn, %{"task_id" => task_id, "key" => key}) do
    case option(task_id, key) do
      %{html: html} when is_binary(html) ->
        conn
        |> put_resp_header("content-security-policy", "sandbox allow-scripts")
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)

      _missing ->
        send_resp(conn, 404, "Not found")
    end
  end

  def screenshot(conn, %{"task_id" => task_id, "key" => key}) do
    case option(task_id, key) do
      %{screenshot_version: version, screenshot_path: path} when is_integer(version) ->
        conn
        |> put_resp_content_type("image/png")
        |> put_resp_header("cache-control", "private, max-age=31536000")
        |> send_file(200, path)

      _missing ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp option(task_id, key) do
    with {:ok, task} <- Pipeline.get_task(task_id),
         %{options: options} <- Pipeline.read_design(task) do
      Enum.find(options, &(&1.key == key))
    else
      _missing -> nil
    end
  end
end
