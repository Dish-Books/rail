defmodule Rail.Release do
  @moduledoc """
  Tasks for executing database migrations, rollbacks, and seeds
  in a production release where Mix is unavailable.
  """

  @app :rail

  @doc """
  Runs pending Ecto migrations.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      path = Ecto.Migrator.migrations_path(repo)
      {:ok, res, _apps} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, path, :up, all: true))
      res
    end
  end

  @doc """
  Rolls back migrations for the given repo and target version.
  """
  def rollback(repo, version) when is_binary(version) do
    rollback(repo, String.to_integer(version))
  end

  def rollback(repo, version) when is_integer(version) do
    load_app()

    path = Ecto.Migrator.migrations_path(repo)
    {:ok, res, _apps} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, path, :down, to: version))
    res
  end

  @doc """
  Rolls back migrations for Rail.Repo and target version.
  """
  def rollback(version) do
    rollback(Rail.Repo, version)
  end

  @doc """
  Loads and executes priv/repo/seeds.exs safely within the release context.
  """
  def seed(custom_seeds_path \\ nil) do
    load_app()

    for repo <- repos() do
      {:ok, res, _apps} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          seeds_path = custom_seeds_path || Path.join([priv_dir(), "repo", "seeds.exs"])

          if File.exists?(seeds_path) do
            {result, _bindings} = Code.eval_file(seeds_path)
            result
          else
            {:error, :seeds_not_found}
          end
        end)

      res
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end

  defp priv_dir do
    Application.app_dir(@app, "priv")
  end
end
