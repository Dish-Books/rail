defmodule Rail.Artifacts.Actions.Materialize do
  @moduledoc false

  import Ecto.Query

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Domain.Embeds.DemoFrame
  alias Rail.Domain.Embeds.DemoSegment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def materialize(_scope, target, dest_scratch_dir, opts \\ []) do
    do_materialize(target, dest_scratch_dir, opts)
  end

  defp do_materialize(%Demo{} = demo, dest_scratch_dir, opts) do
    materialize_demo(demo, dest_scratch_dir, opts)
  end

  defp do_materialize(task_target, dest_scratch_dir, opts) do
    task_id = extract_task_id(task_target)
    opts = maybe_attach_task_project(task_target, task_id, opts)
    kind = Keyword.get(opts, :kind, :all)

    case kind do
      :demo ->
        case get_latest_demo(task_id) do
          %Demo{} = demo -> materialize_demo(demo, dest_scratch_dir, opts)
          nil -> {:error, :demo_not_found}
        end

      :all ->
        materialize_all(task_id, dest_scratch_dir, opts)
    end
  end

  defp extract_task_id(%{id: task_id}), do: to_string(task_id)
  defp extract_task_id(task_id) when is_binary(task_id), do: task_id
  defp extract_task_id(other), do: to_string(other)

  defp get_latest_demo(task_id) do
    Repo.one(from(d in Demo, where: d.task_id == ^task_id, order_by: [desc: d.version], limit: 1))
  end

  defp materialize_all(task_id, dest_scratch_dir, opts) do
    results = %{}

    results =
      case get_latest_demo(task_id) do
        %Demo{} = demo ->
          {:ok, path} = materialize_demo(demo, dest_scratch_dir, opts)
          Map.put(results, :demo, path)

        nil ->
          results
      end

    {:ok, results}
  end

  defp materialize_demo(%Demo{} = demo, dest_scratch_dir, opts) do
    demo_dir =
      if String.ends_with?(dest_scratch_dir, "demo") do
        dest_scratch_dir
      else
        Path.join(dest_scratch_dir, "demo")
      end

    File.mkdir_p!(demo_dir)

    with {:ok, token} <- resolve_token(opts),
         {:ok, segments_data} <- download_demo_segments(demo.segments || [], demo_dir, token, opts) do
      manifest = %{
        "version" => demo.version,
        "outcome" => to_string(demo.outcome),
        "note" => demo.note,
        "segments" => segments_data
      }

      manifest_path = Path.join(demo_dir, "manifest.json")
      File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
      {:ok, demo_dir}
    end
  end

  defp download_demo_segments(segments, demo_dir, token, opts) do
    segments
    |> Enum.reduce_while({:ok, []}, fn %DemoSegment{} = seg, {:ok, acc} ->
      case download_segment_frames(seg, demo_dir, token, opts) do
        {:ok, seg_data} -> {:cont, {:ok, [seg_data | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_segs} -> {:ok, Enum.reverse(rev_segs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download_segment_frames(%DemoSegment{} = seg, demo_dir, token, opts) do
    frames = seg.frames || []

    frames
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {%DemoFrame{} = frame, f_idx}, {:ok, acc} ->
      filename = "ac#{seg.criterion_index}_#{f_idx}.png"
      dest_path = Path.join(demo_dir, filename)

      case maybe_download_file(frame.url, dest_path, token, opts) do
        :ok ->
          frame_map = %{
            "path" => filename,
            "holdMs" => frame.hold_ms,
            "caption" => frame.caption
          }

          {:cont, {:ok, [frame_map | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_frames} ->
        seg_map = %{
          "criterionIndex" => seg.criterion_index,
          "criterion" => seg.criterion,
          "outcome" => to_string(seg.outcome),
          "note" => seg.note,
          "frames" => Enum.reverse(rev_frames)
        }

        {:ok, seg_map}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_download_file(nil, _dest_path, _token, _opts), do: :ok
  defp maybe_download_file("", _dest_path, _token, _opts), do: :ok

  defp maybe_download_file(url, dest_path, token, opts) do
    req_options =
      Application.get_env(:rail, :linear, [])[:req_options] || []

    custom_opts = Keyword.get(opts, :req_options, [])

    req =
      [retry: false]
      |> Req.new()
      |> Req.merge(req_options)
      |> Req.merge(custom_opts)

    headers = [{"authorization", token}]

    case Req.get(req, url: url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        File.write!(dest_path, body)
        :ok

      {:ok, %{status: status}} ->
        {:error, {:download_failed, status, url}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_token(opts) do
    case Keyword.get(opts, :token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _nil ->
        target = Keyword.get(opts, :workspace) || Keyword.get(opts, :project)
        workspace_token(target)
    end
  end

  defp workspace_token(%LinearWorkspace{token: token}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp workspace_token(%Project{linear_workspace: %LinearWorkspace{token: token}})
       when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp workspace_token(%Project{linear_workspace_id: ws_id}) when is_binary(ws_id) do
    case Repo.get(LinearWorkspace, ws_id) do
      %LinearWorkspace{token: token} when is_binary(token) and token != "" ->
        {:ok, token}

      _other ->
        {:error, :no_workspace_token}
    end
  end

  defp workspace_token(_fallback) do
    case Repo.one(from lw in LinearWorkspace, limit: 1) do
      %LinearWorkspace{token: token} when is_binary(token) and token != "" ->
        {:ok, token}

      _other ->
        {:error, :no_workspace_token}
    end
  end

  defp maybe_attach_task_project(%{project_id: project_id} = task, _task_id, opts) do
    opts
    |> Keyword.put_new(:task, task)
    |> Keyword.put_new_lazy(:project, fn ->
      if project_id, do: Repo.get(Project, project_id)
    end)
  end

  defp maybe_attach_task_project(_target, task_id, opts) when is_binary(task_id) and task_id != "" do
    Keyword.put_new_lazy(opts, :project, fn ->
      with %Task{project_id: project_id} when is_binary(project_id) <- Repo.get(Task, task_id),
           %Project{} = project <- Repo.get(Project, project_id) do
        project
      else
        _other -> nil
      end
    end)
  end

  defp maybe_attach_task_project(_target, _task_id, opts), do: opts
end
