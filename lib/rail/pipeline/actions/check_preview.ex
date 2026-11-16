defmodule Rail.Pipeline.Actions.CheckPreview do
  @moduledoc """
  Looks at the deployment of a task's pull request, outside Rail, and records whether it serves the task's head
  commit yet. The first time it does, the Review lead is asked to set up demo examples on it.
  """

  import Ecto.Query

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Clients.Preview, as: Client
  alias Rail.Pipeline.Schemas.Preview
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools

  @doc """
  Checks `task`'s preview and returns `{:ok, preview}`, or `{:error, :disabled}` for a project without previews and
  `{:error, :no_pr}` before the task has a pull request. A deployment that cannot be reached is still deploying.
  """
  def check_preview(%Task{} = task) do
    task = Repo.preload(task, :project, force: true)

    cond do
      not match?(%Project{preview_enabled: true}, task.project) ->
        {:error, :disabled}

      not is_integer(task.pr_number) ->
        {:error, :no_pr}

      true ->
        preview = task |> observe() |> save(task) |> maybe_seed(task)
        {:ok, preview}
    end
  end

  defp observe(%Task{project: project} = task) do
    url = Preview.url(project, task.pr_number)

    head =
      if is_nil(task.cleaned_up_at) and Task.worktree_present?(task),
        do: Git.branch_fingerprint(task.worktree_path)[:head_sha]

    status =
      cond do
        is_nil(head) -> :gone
        match?({:ok, ^head}, Client.version(url, Preview.access(project))) -> :live
        true -> :deploying
      end

    %{url: url, status: status, live_sha: if(status == :live, do: head), checked_at: DateTime.utc_now()}
  end

  defp save(observed, %Task{id: task_id}) do
    previous = Repo.get_by(Preview, task_id: task_id)

    live_at =
      if observed.status == :live and not Preview.live?(previous),
        do: DateTime.utc_now(),
        else: previous && previous.live_at

    # The commit last seen live is kept while a push deploys, so the next one going live can be told apart.
    live_sha = observed.live_sha || (previous && previous.live_sha)

    {:ok, preview} =
      (previous || %Preview{task_id: task_id})
      |> Preview.changeset(Map.put(%{observed | live_sha: live_sha}, :live_at, live_at))
      |> Repo.insert_or_update()

    # Only a change is said, so a page showing the App item is not redrawn every minute.
    if is_nil(previous) or
         {previous.status, previous.live_sha, previous.url} != {preview.status, preview.live_sha, preview.url},
       do: Phoenix.PubSub.broadcast(Rail.PubSub, "previews:#{task_id}", {:preview_changed, preview})

    # A tab open on the deployment a push replaced shows the old commit until it reloads.
    if Preview.live?(preview) and previous != nil and previous.live_sha not in [nil, preview.live_sha],
      do: Tools.send_browser_input(%Task{id: task_id}, Preview.browser_name(), %{"kind" => "navigate", "to" => "reload"})

    preview
  end

  # Once per task, and only once the lead has a conversation to be asked in; until then the next check tries again.
  defp maybe_seed(%Preview{status: :live, seeded_at: nil} = preview, %Task{} = task) do
    with %Run{} = run <- lead_run(task),
         {:ok, _sent_or_queued, _run} <- Pipeline.send_message(Scope.for_system(), run, seed_message(preview, task)) do
      {:ok, seeded} = preview |> Preview.changeset(%{seeded_at: DateTime.utc_now()}) |> Repo.update()
      seeded
    else
      _no_lead_or_refused -> preview
    end
  end

  defp maybe_seed(%Preview{} = preview, %Task{}), do: preview

  defp lead_run(%Task{id: task_id}) do
    Repo.one(
      from r in Run,
        join: role in Role,
        on: role.id == r.role_id,
        where: r.task_id == ^task_id and role.stage == :review_lead,
        order_by: [desc: r.inserted_at],
        limit: 1
    )
  end

  defp seed_message(%Preview{} = preview, %Task{project: project, pr_number: number}) do
    where =
      case Preview.database(project, number) do
        "" <> database -> " Its data is the database `#{database}` in your database tools."
        nil -> ""
      end

    "The preview of this pull request is live at #{preview.url}, signed in at #{Preview.login_url(preview, project)}.#{where} " <>
      "Set up demo examples there that show this change to the user that address signs in: the records a person needs " <>
      "to see each acceptance criterion working, with realistic names and amounts. Then say in a few lines what you set up."
  end
end
