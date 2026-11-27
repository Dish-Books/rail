defmodule Rail.Tools.Actions.BuildCommand do
  @moduledoc false

  import Rail.Tools.Utils.Env
  import Rail.Tools.Utils.MergedPath

  @separator ":"
  @cache_term {__MODULE__, :resolved}

  @doc """
  What `Rail.Tools.run/3` runs for `executable` and `args`: `{path, args, env}`, the executable resolved on the tool
  PATH, its arguments, and the whole environment it gets, git's hardening included. Takes `:env` and `:cd` as `run/3`
  does, for whoever spawns the command itself; any variable of Rail's not in `env` is to be left out of it.
  """
  def build_command(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    cd = Keyword.get(opts, :cd)
    extra = tool_env(executable, Keyword.get(opts, :env, %{}), args, cd)

    {resolve(executable), tool_args(executable, args), env(extra)}
  end

  # Rail runs git in task checkouts whose .git the sandbox can write, so whatever
  # git runs from a repository's own config or hooks would run here, in Rail's
  # container, beside its GitHub token and the Docker socket. Config given in the
  # environment is git's command scope, read after every file and so winning over
  # them, and git passes it on to the gits it starts for submodules:
  #
  # - no hooks: core.hooksPath names a directory that holds none;
  # - no fsmonitor, the command `git status` and the like run first;
  # - plain ssh, not one a repository names;
  # - no askpass program, so a missing credential fails rather than runs one;
  # - no credential helper but the caller's: an empty value clears those read so far;
  # - no signature checks from `git log`, which run the gpg or ssh program config names;
  # - the stock upload and receive programs for `origin`, which on a local path run here.
  #
  # - no submodule recursion, which runs git in a submodule's own git folder,
  #   under the sandbox's own config there.
  #
  # Config under a name of the repository's own choosing cannot be overruled this
  # way: a clean filter a `git status` or worktree diff runs, a merge driver a
  # `merge-tree` runs, and on a git new enough to have them, as 2.54 is, hooks set
  # as `hook.<name>.command`, which core.hooksPath does not reach. Those are closed
  # by Rail writing a checkout's config itself and its sandbox mounting it
  # read-only (Rail.Git.write_checkout_config/2); these overrides are a layer under
  # that, and Rail pushes from the project's clone, never from a checkout.
  @git_config [
    {"core.hooksPath", "/dev/null"},
    {"core.fsmonitor", "false"},
    {"core.sshCommand", "ssh"},
    {"core.askPass", ""},
    {"credential.helper", ""},
    {"log.showSignature", "false"},
    {"submodule.recurse", "false"},
    {"diff.submodule", "short"},
    {"remote.origin.uploadpack", "git-upload-pack"},
    {"remote.origin.receivepack", "git-receive-pack"}
  ]

  # Rail reads a worktree with `git status` and the like while it commits in the
  # same one, and a read that refreshes the index takes its lock: a commit landing
  # then fails on `index.lock: File exists`. Rail's reads leave the index alone.
  #
  # Only the transports Rail's remotes use, so no `ext::` command or remote helper a
  # rewritten URL names; and objects as stored, never as `refs/replace` swaps them.
  @git_env %{
    "GIT_OPTIONAL_LOCKS" => "0",
    "GIT_ALLOW_PROTOCOL" => "file:http:https:ssh",
    "GIT_NO_REPLACE_OBJECTS" => "1"
  }

  # As GIT_CONFIG_PARAMETERS, the form `git -c` passes on, since the port drops a
  # variable whose value is empty and the resets above are empty values. Rail's go
  # first, so a caller's own credential helper comes after the reset that clears the
  # repository's.
  defp tool_env("git", env, args, cd) do
    env = Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
    count = env |> Map.get("GIT_CONFIG_COUNT", "0") |> String.to_integer()
    callers = for i <- 0..(count - 1)//1, do: {env["GIT_CONFIG_KEY_#{i}"], env["GIT_CONFIG_VALUE_#{i}"]}
    own = Map.reject(env, fn {key, _value} -> key =~ ~r/^GIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+)$/ end)
    parameters = Enum.map_join(@git_config ++ callers, " ", fn {key, value} -> quoted(key) <> "=" <> quoted(value) end)

    @git_env
    |> Map.merge(own)
    |> Map.update("GIT_CONFIG_PARAMETERS", parameters, &(parameters <> " " <> &1))
    |> common_dir(args, cd)
  end

  defp tool_env(_executable, env, _args, _cd), do: Map.new(env)

  # A checkout's sandbox may write its .git, all but the config, and a `commondir`
  # file there would have git take its config from wherever that names. Rail's git
  # in a folder with a .git of its own takes that .git as where config lives. Not
  # for a clone or init, which make a repository of their own elsewhere.
  defp common_dir(env, [command | _args], cd) when is_binary(cd) and command not in ["clone", "init"] do
    git_dir = Path.expand(".git", cd)
    if File.dir?(git_dir), do: Map.put_new(env, "GIT_COMMON_DIR", git_dir), else: env
  end

  defp common_dir(env, _args, _cd), do: env

  # git's own quoting for GIT_CONFIG_PARAMETERS: single quotes, with each one inside closed, escaped and reopened.
  defp quoted(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"

  # A diff driver's command and textconv are programs too, named by attributes the
  # checkout holds, and no config can unname them; these flags turn both off. A
  # submodule's own .gitmodules settings outrank config, so only flags keep status,
  # diff and fetch out of submodules.
  defp tool_args("git", ["diff" | rest]), do: ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" | rest]

  defp tool_args("git", [command | rest]) when command in ["log", "show"],
    do: [command, "--no-ext-diff", "--no-textconv" | rest]

  defp tool_args("git", ["status" | rest]), do: ["status", "--ignore-submodules=all" | rest]
  defp tool_args("git", ["fetch" | rest]), do: ["fetch", "--no-recurse-submodules" | rest]

  defp tool_args(_executable, args), do: args

  # Resolves an executable to its absolute path on the tool PATH. Names that
  # already contain a `/` are taken as given, and a name nothing on PATH matches
  # is handed to System.cmd bare, to fail there with its own error.
  defp resolve(executable) do
    if String.contains?(executable, "/") do
      executable
    else
      resolve_once(merged_path(), executable)
    end
  end

  # Lookups are memoized node-wide, keyed by the PATH they were resolved
  # against so a changed PATH never returns a stale hit.
  defp resolve_once(path, executable) do
    cache = :persistent_term.get(@cache_term, %{})
    key = {path, executable}

    case Map.fetch(cache, key) do
      {:ok, resolved} ->
        resolved

      :error ->
        resolved = scan(path, executable)
        :persistent_term.put(@cache_term, Map.put(cache, key, resolved))
        resolved
    end
  end

  defp scan(path, executable) do
    path
    |> String.split(@separator)
    |> Enum.find_value(executable, fn dir ->
      candidate = Path.join(dir, executable)
      if executable?(candidate), do: candidate
    end)
  end

  defp executable?(candidate) do
    case File.stat(candidate) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end
end
