defmodule Rail.Pipeline.Actions.OpenPreviewTab do
  @moduledoc false

  alias Rail.Pipeline.Clients.Preview, as: Client
  alias Rail.Pipeline.Schemas.Preview
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools

  @doc """
  Opens `task`'s live preview in Rail's browser at its project's login path, past Cloudflare Access, so the person
  watching the App item lands signed in. Asked again, it goes back to the login path. Returns `:ok`,
  `{:error, :not_live}`, or why the browser could not open.
  """
  def open_preview_tab(%Task{} = task) do
    %Task{project: project} = task = Repo.preload(task, :project)

    with %Preview{status: :live} = preview <- Repo.get_by(Preview, task_id: task.id) || {:error, :not_live},
         {:ok, cookies} <- Client.access_cookies(preview.url, Preview.access(project)),
         :ok <- Tools.open_app_tab(task, Preview.browser_name(), Preview.login_url(preview, project), cookies) do
      # Said again once the tab is somewhere, so a page showing the preview reads its address afresh.
      Phoenix.PubSub.broadcast(Rail.PubSub, "previews:#{task.id}", {:preview_changed, preview})
    else
      %Preview{} -> {:error, :not_live}
      {:error, reason} -> {:error, reason}
    end
  end
end
