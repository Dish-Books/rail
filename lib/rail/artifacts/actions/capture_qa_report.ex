defmodule Rail.Artifacts.Actions.CaptureQaReport do
  @moduledoc false

  import Rail.Artifacts.Utils.CommentFormatter
  import Rail.Artifacts.Utils.MimeType

  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Artifacts.Validators.QaValidator
  alias Rail.Issues
  alias Rail.Repo
  alias Rail.Scope

  def capture_qa_report(scope, target, scratch_dir_or_opts, opts \\ []) do
    if authorized?(scope) do
      {task_id, scratch_dir, combined_opts} = normalize_args(target, scratch_dir_or_opts, opts)
      do_capture_qa_report(scope, task_id, scratch_dir, combined_opts)
    else
      {:error, :not_authorized}
    end
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp normalize_args(target, scratch_dir, opts) when is_binary(scratch_dir) do
    task_id = extract_task_id(target)
    {task_id, scratch_dir, opts}
  end

  defp normalize_args(target, opts, _extra_opts) when is_list(opts) do
    task_id = extract_task_id(target)
    scratch_dir = Keyword.get(opts, :scratch_dir) || "/tmp/rail_scratch/#{task_id}"
    {task_id, scratch_dir, opts}
  end

  defp extract_task_id(%{id: task_id}), do: to_string(task_id)
  defp extract_task_id(task_id) when is_binary(task_id), do: task_id
  defp extract_task_id(other), do: to_string(other)

  defp do_capture_qa_report(scope, task_id, scratch_dir, opts) do
    qa_dir = resolve_qa_dir(scratch_dir)

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
        maybe_post_comment(scope, report, opts)
        {:ok, report}
      end
    end
  end

  defp resolve_qa_dir(path) do
    if File.exists?(Path.join(path, "manifest.json")) do
      path
    else
      Path.join(path, "qa")
    end
  end

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
      case upload_artifact_if_image(scope, art, opts) do
        {:ok, updated_art} -> {:cont, {:ok, [updated_art | acc_arts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_arts} -> {:ok, Map.put(row, :artifacts, Enum.reverse(rev_arts))}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp maybe_post_comment(scope, qa_report, opts) do
    issue = Keyword.get(opts, :issue)

    if issue do
      comment_body = format_qa_comment(qa_report)
      owner_user = Keyword.get(opts, :owner_user)
      Issues.comment(scope, issue, comment_body, owner_user)
    end

    :ok
  end
end
