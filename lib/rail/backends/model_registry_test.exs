defmodule Rail.Backends.ModelRegistryTest do
  use Rail.DataCase, async: false

  alias Rail.Backends.ModelOption
  alias Rail.Backends.ModelRegistry

  setup do
    ModelRegistry.clear_cache()

    on_exit(fn ->
      ModelRegistry.clear_cache()
    end)

    :ok
  end

  test "default_models/1 returns predefined fallback lists" do
    agy_models = ModelRegistry.default_models(:agy)
    assert length(agy_models) == 5
    assert %ModelOption{id: "gemini-3.8-flash-high"} = hd(agy_models)

    claude_models = ModelRegistry.default_models(:claude)
    assert length(claude_models) == 7
    assert %ModelOption{id: "claude-fable-5-1"} = hd(claude_models)
  end

  test "get_cached_models/1, put_cached_models/2, and clear_cache/1 manage ETS cache" do
    test_models = [%ModelOption{id: "custom-model", display_name: "Custom Model"}]
    ModelRegistry.put_cached_models("custom_backend", test_models)

    assert ModelRegistry.get_cached_models("custom_backend") == test_models
    assert ModelRegistry.get_cached_models("unknown_backend") == []

    ModelRegistry.clear_cache("custom_backend")
    assert ModelRegistry.get_cached_models("custom_backend") == []
  end

  test "fetch_available_models/2 returns cached models without running probe unless force_refresh is true" do
    test_models = [%ModelOption{id: "cached-model", display_name: "Cached Model"}]
    ModelRegistry.put_cached_models(:agy, test_models)

    assert ModelRegistry.fetch_available_models(:agy) == test_models

    # When force_refresh: true, calls runner
    runner = fn _exe, _args, _opts ->
      output = "gemini-ultra\tGemini Ultra\n"
      {:ok, output, 0}
    end

    refreshed = ModelRegistry.fetch_available_models(:agy, force_refresh: true, runner: runner)
    assert [%ModelOption{id: "gemini-ultra", display_name: "Gemini Ultra (gemini-ultra)"}] = refreshed
  end

  test "fetch_available_models(:agy) parses CLI output, skips fetching lines, and handles single-word lines" do
    output = """
    Fetching available models...
    gemini-2.5-flash    Gemini 2.5 Flash
    gemini-2.5-pro\tGemini 2.5 Pro
    standalone-model
    gemini-2.5-flash    Duplicate Line
    """

    runner = fn _exe, ["models"], _opts -> {:ok, output, 0} end

    models = ModelRegistry.fetch_available_models(:agy, runner: runner, force_refresh: true)

    assert [
             %ModelOption{id: "gemini-2.5-flash", display_name: "Gemini 2.5 Flash (gemini-2.5-flash)"},
             %ModelOption{id: "gemini-2.5-pro", display_name: "Gemini 2.5 Pro (gemini-2.5-pro)"},
             %ModelOption{id: "standalone-model", display_name: "standalone-model (standalone-model)"}
           ] = models
  end

  test "fetch_available_models(:agy) falls back to defaults on error or empty output" do
    runner_err = fn _exe, _args, _opts -> {:error, :timeout} end
    models = ModelRegistry.fetch_available_models(:agy, runner: runner_err, force_refresh: true)
    assert models == ModelRegistry.default_models(:agy)
  end

  test "fetch_available_models(:claude) seeds aliases, greps binary, filters latest and dates, and sorts descending" do
    grep_output = """
    claude-3-5-sonnet-20241022
    claude-3-7-sonnet
    claude-3-5-haiku
    claude-3-opus
    claude-latest
    claude-3-5-sonnet
    """

    runner = fn _exe, _args, _opts -> {:ok, grep_output, 0} end

    models = ModelRegistry.fetch_available_models(:claude, runner: runner, force_refresh: true)

    # Starts with seeded aliases
    assert %ModelOption{id: "opus"} = Enum.at(models, 0)
    assert %ModelOption{id: "sonnet"} = Enum.at(models, 1)
    assert %ModelOption{id: "haiku"} = Enum.at(models, 2)

    # Followed by descending sorted grep matches (excluding -20241022 and latest)
    ids = Enum.map(models, & &1.id)
    assert "claude-3-7-sonnet" in ids
    assert "claude-3-5-sonnet" in ids
    assert "claude-3-5-haiku" in ids
    assert "claude-3-opus" in ids

    refute "claude-latest" in ids
    refute "claude-3-5-sonnet-20241022" in ids
  end

  test "fetch_available_models(:claude) falls back to defaults when grep finds <= 3 models" do
    runner_empty = fn _exe, _args, _opts -> {:ok, "", 0} end

    models = ModelRegistry.fetch_available_models(:claude, runner: runner_empty, force_refresh: true)

    # Seeded 3 aliases + missing defaults
    assert length(models) == 7
    ids = Enum.map(models, & &1.id)
    assert "opus" in ids
    assert "sonnet" in ids
    assert "haiku" in ids
    assert "claude-fable-5-1" in ids
  end

  test "handles runner errors, exceptions, symlink resolution, and custom executable paths" do
    # agy runner raising
    raising_runner = fn _exe, _args, _opts -> raise "runner exploded" end

    assert [%ModelOption{} | _rest1] =
             ModelRegistry.fetch_available_models(:agy, runner: raising_runner, force_refresh: true)

    # agy with executable_path
    dummy_runner = fn _exe, _args, _opts -> {:ok, "", 0} end

    assert [%ModelOption{} | _rest2] =
             ModelRegistry.fetch_available_models(:agy,
               executable_path: "agy",
               runner: dummy_runner,
               force_refresh: true
             )

    # claude runner raising
    assert [%ModelOption{} | _rest3] =
             ModelRegistry.fetch_available_models(:claude, runner: raising_runner, force_refresh: true)

    # claude runner returning error
    err_runner = fn _exe, _args, _opts -> {:error, :eacces} end

    assert [%ModelOption{} | _rest4] =
             ModelRegistry.fetch_available_models(:claude, runner: err_runner, force_refresh: true)

    # claude with executable_path pointing to a regular file (triggers File.read_link non-symlink branch)
    assert [%ModelOption{} | _rest5] =
             ModelRegistry.fetch_available_models(:claude,
               executable_path: __ENV__.file,
               runner: dummy_runner,
               force_refresh: true
             )

    # claude with nonexistent executable path (triggers File.exists? false branch)
    assert [%ModelOption{} | _rest6] =
             ModelRegistry.fetch_available_models(:claude,
               executable_path: "/nonexistent/binary_path_12345",
               runner: dummy_runner,
               force_refresh: true
             )

    # claude with symlink executable path (triggers File.read_link {:ok, target} branch)
    symlink_path = Path.join(System.tmp_dir!(), "claude_symlink_#{System.unique_integer([:positive])}")
    File.ln_s!(__ENV__.file, symlink_path)

    assert [%ModelOption{} | _rest7] =
             ModelRegistry.fetch_available_models(:claude,
               executable_path: symlink_path,
               runner: dummy_runner,
               force_refresh: true
             )

    File.rm!(symlink_path)

    # normalize_backend with non-atom non-string
    ModelRegistry.clear_cache(12_345)
    assert ModelRegistry.default_models(12_345) == ModelRegistry.default_models(:claude)
  end
end
