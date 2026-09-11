defmodule Rail.Artifacts.Actions.CaptureQaReport do
  @moduledoc false

  import Rail.Artifacts.Utils.CommentFormatter
  import Rail.Artifacts.Utils.MimeType

  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Artifacts.Validators.QaValidator
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  def capture_qa_report(scope, target, scratch_dir_or_opts, opts \\ []) do
    {task, task_id, scratch_dir, combined_opts} = normalize_args(target, scratch_dir_or_opts, opts)
    do_capture_qa_report(scope, task, task_id, scratch_dir, combined_opts)
  end

  defp normalize_args(target, scratch_dir, opts) when is_binary(scratch_dir) do
    {task, task_id} = resolve_task_and_id(target)
    {task, task_id, scratch_dir, opts}
  end

  defp normalize_args(target, opts, _extra_opts) when is_list(opts) do
    {task, task_id} = resolve_task_and_id(target)
    scratch_dir = Keyword.fetch!(opts, :scratch_dir)
    {task, task_id, scratch_dir, opts}
  end

  defp resolve_task_and_id(%Task{id: id} = task), do: {task, to_string(id)}
  defp resolve_task_and_id(%{id: task_id}), do: {Repo.get(Task, task_id), to_string(task_id)}
  defp resolve_task_and_id(task_id) when is_binary(task_id), do: {Repo.get(Task, task_id), task_id}
  defp resolve_task_and_id(other), do: {nil, to_string(other)}

  defp do_capture_qa_report(scope, task, task_id, scratch_dir, opts) do
    qa_dir = resolve_qa_dir(scratch_dir)

    opts =
      Keyword.put_new_lazy(opts, :project, fn ->
        cond do
          match?(%Project{}, task && task.project) ->
            task.project

          task && is_binary(task.project_id) && task.project_id != "" ->
            Repo.get(Project, task.project_id)

          true ->
            nil
        end
      end)

    with {:ok, qa_data} <- QaValidator.validate(qa_dir, opts),
         {:ok, rows_with_assets} <- upload_qa_assets(scope, qa_data.rows, opts) do
      role_run_id = Keyword.get(opts, :role_run_id)
      commit = Keyword.get(opts, :commit) || qa_data[:commit]

      qa_attrs = %{
        task_id: task_id,
        role_run_id: role_run_id,
        commit: commit,
        session: qa_data[:session] || %{},
        rows: rows_with_assets
      }

      with {:ok, report} <- %QaReport{} |> QaReport.changeset(qa_attrs) |> Repo.insert() do
        maybe_post_comment(scope, report, task, opts)
        {:ok, report}
      end
    end
  end

  defp resolve_qa_dir(scratch_dir), do: Path.join(scratch_dir, "qa")

  defp upload_qa_assets(scope, rows, opts) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc_rows} ->
      case upload_row_artifacts(scope, row, opts) do
        {:ok, updated_row} -> {:cont, {:ok, [updated_row | acc_rows]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_rows} -> {:ok, Enum.reverse(rev_rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_row_artifacts(scope, row, opts) do
    artifacts = Map.get(row, :artifacts, [])

    artifacts
    |> Enum.reduce_while({:ok, []}, fn art, {:ok, acc_arts} ->
      case populate_and_upload_artifact(scope, art, opts) do
        {:ok, updated_art} -> {:cont, {:ok, [updated_art | acc_arts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_arts} -> {:ok, Map.put(row, :artifacts, Enum.reverse(rev_arts))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp populate_and_upload_artifact(scope, %{kind: :image} = art, opts) do
    upload_artifact_if_image(scope, art, opts)
  end

  defp populate_and_upload_artifact(_scope, %{kind: :text, resolved_path: path} = art, _opts) when is_binary(path) do
    updated =
      if (is_nil(art[:text]) or art[:text] == "") and File.exists?(path) do
        Map.put(art, :text, File.read!(path))
      else
        art
      end

    {:ok, updated}
  end

  defp populate_and_upload_artifact(_scope, art, _opts), do: {:ok, art}

  defp upload_artifact_if_image(scope, %{kind: :image, resolved_path: path} = art, opts) when is_binary(path) do
    case File.read(path) do
      {:ok, binary} ->
        filename = art[:name] || Path.basename(path)
        content_type = mime_type(filename)

        case Issues.upload_asset(scope, filename, content_type, binary, opts) do
          {:ok, %{asset_url: asset_url}} ->
            {:ok, Map.put(art, :url, asset_url)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _reason} ->
        {:ok, art}
    end
  end

  defp upload_artifact_if_image(_scope, art, _opts), do: {:ok, art}

  defp maybe_post_comment(scope, qa_report, task, opts) do
    issue = resolve_comment_issue(task, opts)

    if issue do
      comment_body = format_qa_comment(qa_report)
      owner_user = resolve_comment_owner(issue, opts)
      Issues.comment(scope, issue, comment_body, owner_user)
    end

    :ok
  end

  defp resolve_comment_issue(task, opts) do
    case Keyword.get(opts, :issue) do
      %Issue{} = iss ->
        iss

      _other ->
        cond do
          task && match?(%Issue{}, task.issue) ->
            task.issue

          task && is_binary(task.issue_id) && task.issue_id != "" ->
            Repo.get(Issue, task.issue_id)

          true ->
            nil
        end
    end
  end

  defp resolve_comment_owner(issue, opts) do
    case Keyword.get(opts, :owner_user) do
      %User{} = user ->
        user

      _other ->
        cond do
          match?(%User{}, issue.owner_user) ->
            issue.owner_user

          is_binary(issue.owner_user_id) && issue.owner_user_id != "" ->
            Repo.get(User, issue.owner_user_id)

          true ->
            nil
        end
    end
  end
end
