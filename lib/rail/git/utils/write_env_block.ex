defmodule Rail.Git.Utils.WriteEnvBlock do
  @moduledoc false

  import Rail.Git.Utils.MergeEnvBlock

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  @doc """
  Writes the clone's `.env` into the top of `task`'s checkout's, between Rail's markers, keeping each of the
  checkout's own lines that sets no variable the clone's does, and has git ignore it. The checkout is on Rail's disk
  under the `:local` runtime and in the task's sandbox otherwise. Returns `:ok`, `{:error, :not_running}` when the
  sandbox is not there to write in, or `{:error, "<path>: <reason>"}`.
  """
  # Takes no lock: callers hold the clone's.
  def write_env_block(%Project{clone_path: clone}, %Task{} = task) do
    source = Path.join(clone, ".env")

    case File.read(source) do
      {:ok, project_env} -> write(Rail.sandbox_runtime(), project_env, clone, task)
      {:error, :enoent} -> :ok
      {:error, reason} -> said({:error, reason}, source)
    end
  end

  defp write(:local, project_env, clone, %Task{worktree_path: worktree_path}) do
    target = Path.join(worktree_path, ".env")

    current =
      case File.read(target) do
        {:ok, text} -> {:ok, text}
        {:error, :enoent} -> {:ok, nil}
        {:error, reason} -> said({:error, reason}, target)
      end

    with {:ok, current} <- current,
         :ok <- exclude_env(clone, worktree_path) do
      target |> File.write(merge_env_block(project_env, current)) |> said(target)
    end
  end

  defp write(:docker, project_env, _clone, %Task{worktree_path: worktree_path} = task) do
    target = Path.join(worktree_path, ".env")
    exclude = Path.join(worktree_path, ".git/info/exclude")

    with {:ok, current} <- read(task, target),
         {:ok, excluded} <- read(task, exclude),
         files = [file(target, merge_env_block(project_env, current)) | exclude_file(exclude, excluded)],
         {:ok, _written} <- Tools.call_sandbox(task, "write", %{"files" => files}) do
      :ok
    else
      {:error, :not_running} -> {:error, :not_running}
      {:error, reason} -> {:error, "#{target}: #{inspect(reason)}"}
    end
  end

  defp read(%Task{} = task, path) do
    case Tools.call_sandbox(task, "read", %{"path" => path}) do
      {:ok, %{"data" => data}} -> {:ok, Base.decode64!(data)}
      {:ok, %{"missing" => true}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file(path, text), do: %{"path" => path, "data" => Base.encode64(text), "mode" => 0o644}

  defp exclude_file(path, text) do
    lines =
      case String.trim_trailing(text || "") do
        "" -> "/.env\n"
        kept -> kept <> "\n/.env\n"
      end

    if excludes_env?(text), do: [], else: [file(path, lines)]
  end

  # A worktree reads its clone's exclude file; a clone of its own reads only its own.
  defp exclude_env(clone, worktree_path) do
    own = Path.join(worktree_path, ".git")
    info = Path.join(if(File.dir?(own), do: own, else: Path.join(clone, ".git")), "info")
    exclude = Path.join(info, "exclude")

    with :ok <- info |> File.mkdir_p() |> said(info) do
      case File.read(exclude) do
        {:ok, text} ->
          if excludes_env?(text),
            do: :ok,
            else: exclude |> File.write(String.trim_trailing(text) <> "\n/.env\n") |> said(exclude)

        {:error, :enoent} ->
          exclude |> File.write("/.env\n") |> said(exclude)

        {:error, reason} ->
          said({:error, reason}, exclude)
      end
    end
  end

  defp excludes_env?(text), do: is_binary(text) and "/.env" in String.split(text, ~r/\r?\n/)

  defp said(:ok, _path), do: :ok
  defp said({:error, reason}, path), do: {:error, "#{path}: #{:file.format_error(reason)}"}
end
