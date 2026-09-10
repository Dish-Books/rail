defmodule Rail.Artifacts.Actions.CaptureDemo do
  @moduledoc false

  import Ecto.Query
  import Rail.Artifacts.Utils.CommentFormatter
  import Rail.Artifacts.Utils.MimeType

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Validators.DemoValidator
  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  def capture_demo(scope, target, scratch_dir_or_opts, opts \\ []) do
    if authorized?(scope) do
      {task, task_id, scratch_dir, combined_opts} = normalize_args(target, scratch_dir_or_opts, opts)
      do_capture_demo(scope, task, task_id, scratch_dir, combined_opts)
    else
      {:error, :not_authorized}
    end
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp normalize_args(target, scratch_dir, opts) when is_binary(scratch_dir) do
    {task, task_id} = resolve_task_and_id(target)
    {task, task_id, scratch_dir, opts}
  end

  defp normalize_args(target, opts, _extra_opts) when is_list(opts) do
    {task, task_id} = resolve_task_and_id(target)
    scratch_dir = Keyword.get(opts, :scratch_dir) || "/tmp/rail_scratch/#{task_id}"
    {task, task_id, scratch_dir, opts}
  end

  defp resolve_task_and_id(%Task{id: id} = task), do: {task, to_string(id)}
  defp resolve_task_and_id(%{id: task_id}), do: {Repo.get(Task, task_id), to_string(task_id)}
  defp resolve_task_and_id(task_id) when is_binary(task_id), do: {Repo.get(Task, task_id), task_id}
  defp resolve_task_and_id(other), do: {nil, to_string(other)}

  defp do_capture_demo(scope, task, task_id, scratch_dir, opts) do
    demo_dir = resolve_demo_dir(scratch_dir)

    with {:ok, demo_data} <- DemoValidator.validate(demo_dir, opts),
         {:ok, segments_with_assets} <- upload_demo_assets(scope, demo_data.segments, opts) do
      version = next_version(task_id, demo_data[:version])

      {resolved_head_sha, resolved_dirty_digest} =
        if task && is_binary(task.worktree_path) && File.dir?(task.worktree_path) do
          case Git.branch_fingerprint(task.worktree_path, ignore_axis: true) do
            %{head_sha: sha, dirty_digest: digest} -> {sha, digest}
            _other -> {nil, nil}
          end
        else
          {nil, nil}
        end

      head_sha = Keyword.get(opts, :head_sha) || demo_data[:head_sha] || resolved_head_sha
      dirty_digest = Keyword.get(opts, :dirty_digest) || demo_data[:dirty_digest] || resolved_dirty_digest
      commit = Keyword.get(opts, :commit) || demo_data[:commit] || head_sha

      demo_attrs = %{
        task_id: task_id,
        version: version,
        recorded_at: demo_data[:recorded_at] || DateTime.utc_now(),
        commit: commit,
        head_sha: head_sha,
        dirty_digest: dirty_digest,
        outcome: demo_data[:outcome],
        note: demo_data[:note],
        stale: false,
        segments: segments_with_assets
      }

      demo_struct = struct(Demo, demo_attrs)

      with {:ok, comment_id} <- maybe_post_comment(scope, demo_struct, task, opts) do
        final_attrs =
          if comment_id do
            Map.put(demo_attrs, :linear_comment_id, comment_id)
          else
            demo_attrs
          end

        %Demo{}
        |> Demo.changeset(final_attrs)
        |> Repo.insert()
      end
    end
  end

  defp resolve_demo_dir(path) do
    cond do
      File.exists?(Path.join(path, "manifest.json")) ->
        path

      File.exists?(Path.join([path, "demo", "manifest.json"])) ->
        Path.join(path, "demo")

      File.exists?(Path.join([path, ".axis", "demo", "manifest.json"])) ->
        Path.join([path, ".axis", "demo"])

      true ->
        Path.join(path, "demo")
    end
  end

  defp next_version(task_id, manifest_version) do
    query =
      from d in Demo,
        where: d.task_id == ^task_id,
        order_by: [desc: d.version],
        limit: 1,
        select: d.version

    case Repo.one(query) do
      latest when is_integer(latest) -> max(latest + 1, manifest_version || 1)
      nil -> manifest_version || 1
    end
  end

  defp upload_demo_assets(scope, segments, opts) do
    segments
    |> Enum.reduce_while({:ok, []}, fn seg, {:ok, acc_segs} ->
      case upload_segment_frames(scope, seg, opts) do
        {:ok, updated_seg} -> {:cont, {:ok, [updated_seg | acc_segs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_segs} -> {:ok, Enum.reverse(rev_segs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_segment_frames(scope, %{outcome: :recorded, frames: frames} = seg, opts) when is_list(frames) do
    frames
    |> Enum.reduce_while({:ok, []}, fn frame, {:ok, acc_frames} ->
      case upload_frame(scope, frame, opts) do
        {:ok, updated_frame} -> {:cont, {:ok, [updated_frame | acc_frames]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_frames} -> {:ok, Map.put(seg, :frames, Enum.reverse(rev_frames))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_segment_frames(_scope, seg, _opts), do: {:ok, seg}

  defp upload_frame(scope, frame, opts) do
    file_path = frame[:resolved_path] || frame["resolved_path"] || frame[:path] || frame["path"]
    filename = Path.basename(file_path)

    case File.read(file_path) do
      {:ok, binary} ->
        content_type = mime_type(filename)

        case Issues.upload_asset(scope, filename, content_type, binary, opts) do
          {:ok, %{asset_url: asset_url, asset_id: asset_id}} ->
            updated =
              frame
              |> Map.put(:url, asset_url)
              |> Map.put(:linear_asset_id, asset_id)

            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Failed to read demo frame #{file_path}: #{inspect(reason)}"}
    end
  end

  defp maybe_post_comment(scope, demo_struct, task, opts) do
    issue =
      Keyword.get(opts, :issue) ||
        (task && task.issue_id && Repo.get(Rail.Issues.Schemas.Issue, task.issue_id))

    if issue do
      comment_body = format_demo_comment(demo_struct)

      owner_user =
        Keyword.get(opts, :owner_user) ||
          (task && task.owner_user_id && Repo.get(User, task.owner_user_id))

      case Issues.comment(scope, issue, comment_body, owner_user) do
        {:ok, %{id: comment_id}} -> {:ok, comment_id}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end
end
